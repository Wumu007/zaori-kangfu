package com.medreminder.med_reminder

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.util.zip.ZipInputStream

/**
 * 离线语音识别（Vosk）
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么必须自带模型（用户 V1.8.0 实测日志）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 三条系统路径全部撞墙，且证据互相印证：
 * - 原生识别器：启动即 `error code=8`（RECOGNIZER_BUSY）或 7 秒零事件；
 * - 插件路径：`listen` 后 1.2 秒就 `done`，累计 0 字；
 * - 系统对话框：从「打开」到「返回无文字」只隔 4 毫秒 —— 根本没弹出来；
 * - 加上 <queries> 声明后 `系统语音服务=[]` 依然为空。
 *
 * 结论：这台设备没有可用的中文语音识别引擎（典型的「依赖在线服务的
 * 引擎在国内连不上」或「厂商语音不对外开放」）。继续在调用层修没有意义。
 *
 * 所以改成**把模型打包进 APK**：
 * - 模型 `vosk-model-small-cn-0.3`（31.7MB zip）由 CI 构建时下载并放进 assets；
 * - 首次使用时解压到应用私有目录（约 70MB，一次性）；
 * - AudioRecord 16kHz 单声道采集，直接喂给 Vosk 识别；
 * - 全程离线，不联网、不读系统语音服务、不需要任何额外权限。
 *
 * 代价：APK 体积增加约 40MB；首次准备约 3–5 秒。
 */
object OfflineAsr {

    private const val ASSET_ZIP = "vosk-model-zh.zip"
    private const val TARGET_DIR = "vosk-zh"
    private const val SAMPLE_RATE = 16000

    @Volatile private var model: Model? = null
    @Volatile private var recognizer: Recognizer? = null
    @Volatile private var running = false

    private var audioThread: Thread? = null
    private var record: AudioRecord? = null

    /** 事件回调：type = ready / partial / result / error / end */
    private var emit: ((String, String, Int) -> Unit)? = null

    /** APK 里是否带了模型（CI 没下到模型时为 false，前端据此降级） */
    @JvmStatic
    fun hasModel(context: Context): Boolean {
        return try {
            context.assets.open(ASSET_ZIP).close()
            true
        } catch (_: Exception) {
            // 也允许已经解压过的情况（assets 被裁剪但本地还在）
            modelRoot(context) != null
        }
    }

    /**
     * 准备模型（解压 + 加载）。**耗时 3–5 秒，必须在后台线程调用。**
     * 返回 true 表示可以开始识别。
     */
    @JvmStatic
    fun prepare(context: Context): Boolean {
        if (model != null) return true
        return try {
            val root = ensureExtracted(context) ?: return false
            model = Model(root.absolutePath)
            true
        } catch (e: Throwable) {
            android.util.Log.e("MedReminder", "offline asr prepare failed: $e")
            model = null
            false
        }
    }

    /**
     * 开始识别。
     *
     * @param onEvent (type, text, code)
     *   type=ready 模型就绪；partial 中间结果；result 最终结果；
     *   error 出错（code 为内部错误码）；end 会话结束
     */
    @JvmStatic
    fun start(context: Context, onEvent: (String, String, Int) -> Unit): Boolean {
        if (running) return false
        emit = onEvent

        // 准备模型（这里可能阻塞 3–5 秒，调用方在后台线程）
        if (!prepare(context)) {
            onEvent("error", "model_unavailable", 1)
            return false
        }
        val m = model ?: run {
            onEvent("error", "model_unavailable", 1)
            return false
        }

        return try {
            val rec = Recognizer(m, SAMPLE_RATE.toFloat())
            recognizer = rec
            startAudioLoop(rec)
            running = true
            onEvent("ready", "", 0)
            true
        } catch (e: Throwable) {
            android.util.Log.e("MedReminder", "offline asr start failed: $e")
            onEvent("error", e.message ?: "start_failed", 2)
            cleanup()
            false
        }
    }

    @JvmStatic
    fun stop() {
        cleanup()
        emit?.invoke("end", "", 0)
    }

    @JvmStatic
    fun isRunning(): Boolean = running

    // ------------------------------------------------------------ 音频循环

    private fun startAudioLoop(rec: Recognizer) {
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufSize = if (minBuf > 0) maxOf(minBuf * 2, 4096) else 8192

        audioThread = Thread {
            var ar: AudioRecord? = null
            try {
                ar = AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufSize,
                )
                if (ar.state != AudioRecord.STATE_INITIALIZED) {
                    emit?.invoke("error", "audio_init_failed", 3)
                    return@Thread
                }
                record = ar
                ar.startRecording()

                val buffer = ByteArray(bufSize)
                var lastPartial = ""
                var lastEmitAt = 0L

                while (running && !Thread.currentThread().isInterrupted) {
                    val n = ar.read(buffer, 0, buffer.size)
                    if (n <= 0) continue
                    val ok = try {
                        rec.acceptWaveForm(buffer, n)
                    } catch (e: Throwable) {
                        emit?.invoke("error", e.message ?: "accept_failed", 4)
                        break
                    }

                    // 中间结果：每 400ms 最多推一次，避免刷屏
                    if (!ok) {
                        val now = System.currentTimeMillis()
                        if (now - lastEmitAt > 400) {
                            lastEmitAt = now
                            val partial = jsonField(rec.partialResult, "partial")
                            if (partial.isNotEmpty() && partial != lastPartial) {
                                lastPartial = partial
                                emit?.invoke("partial", partial, 0)
                            }
                        }
                    } else {
                        val text = jsonField(rec.finalResult, "text")
                        if (text.isNotBlank()) {
                            emit?.invoke("result", text, 0)
                        }
                    }
                }
            } catch (e: Throwable) {
                emit?.invoke("error", e.message ?: "audio_error", 5)
            } finally {
                try { ar?.stop() } catch (_: Exception) {}
                try { ar?.release() } catch (_: Exception) {}
                record = null
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun jsonField(json: String, key: String): String {
        return try {
            JSONObject(json).optString(key, "")
        } catch (_: Exception) {
            ""
        }
    }

    private fun cleanup() {
        running = false
        try { audioThread?.interrupt() } catch (_: Exception) {}
        audioThread = null
        try { record?.stop() } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        record = null
        try { recognizer?.close() } catch (_: Exception) {}
        recognizer = null
    }

    // ------------------------------------------------------------ 模型解压

    /** 首次调用把 assets 里的 zip 解到 filesDir，返回模型根目录 */
    private fun ensureExtracted(context: Context): File? {
        modelRoot(context)?.let { return it }

        val base = File(context.filesDir, TARGET_DIR)
        if (!base.exists()) base.mkdirs()

        try {
            context.assets.open(ASSET_ZIP).use { input ->
                ZipInputStream(input).use { zis ->
                    var entry = zis.nextEntry
                    while (entry != null) {
                        val out = File(base, entry.name)
                        // 防 zip slip
                        if (!out.canonicalPath.startsWith(base.canonicalPath)) {
                            entry = zis.nextEntry
                            continue
                        }
                        if (entry.isDirectory) {
                            out.mkdirs()
                        } else {
                            out.parentFile?.mkdirs()
                            out.outputStream().use { zis.copyTo(it) }
                        }
                        entry = zis.nextEntry
                    }
                }
            }
        } catch (e: Throwable) {
            android.util.Log.e("MedReminder", "extract model failed: $e")
            return null
        }
        return modelRoot(context)
    }

    /**
     * 找模型根目录：Vosk 模型的标志是含 `am/` 或 `conf/` 子目录。
     * zip 里通常有一层 `vosk-model-small-cn-0.3/`，所以需要递归找。
     */
    private fun modelRoot(context: Context): File? {
        val base = File(context.filesDir, TARGET_DIR)
        if (!base.exists()) return null
        return findRoot(base, 0)
    }

    private fun findRoot(dir: File, depth: Int): File? {
        if (depth > 3) return null
        val names = dir.list()?.toSet() ?: return null
        if (names.contains("am") || names.contains("conf")) return dir
        for (f in dir.listFiles() ?: return null) {
            if (f.isDirectory) {
                findRoot(f, depth + 1)?.let { return it }
            }
        }
        return null
    }
}
