package com.medreminder.med_reminder

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.BufferedInputStream
import java.io.File
import java.util.zip.ZipInputStream

/**
 * 离线语音识别（Vosk）
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么自带模型（用户 V1.8.0 日志）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 三条系统路径全部撞墙且证据互相印证：原生识别器 `error code=8`、
 * 插件 `listen` 后 1.2 秒即 `done`、系统对话框 4 毫秒返回、
 * 加了 <queries> 后 `系统语音服务=[]` 依然为空。
 * 结论：这台设备没有可用的中文识别引擎。所以把模型打进 APK，
 * 完全离线、不碰系统语音服务。
 *
 * ═══════════════════════════════════════════════════════════════════
 * V1.10.0 修复：模型根目录判定写错了（用户 V1.9.0 日志 model_unavailable）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 日志现象：每次点语音，1 秒左右就 `路径O 错误 | model_unavailable code=1`，
 * 连续 20 次全都一样，而且**每次都要重新解压**（所以每次都耗时约 1 秒）。
 *
 * 根因：V1.9.0 用「子目录里有 am 或 conf」来认模型根目录 —— 那是旧版
 * Kaldi 布局。而 `vosk-model-small-cn-0.3` 是**扁平布局**（构建日志里的
 * `unzip -l` 可证）：
 *
 *     vosk-model-small-cn-0.3/README
 *     vosk-model-small-cn-0.3/final.mdl      ← 直接在根
 *     vosk-model-small-cn-0.3/Gr.fst         ← 直接在根
 *     vosk-model-small-cn-0.3/disambig_tid.int
 *
 * 没有 am/ 也没有 conf/，于是 findRoot() 永远返回 null →
 * ensureExtracted() 返回 null → prepare() 返回 false →
 * 报 model_unavailable；并且下次仍然「找不到已解压模型」，又解压一遍。
 *
 * 修复：
 * 1. 认 `final.mdl`（扁平布局）+ `am/final.mdl`（旧布局）两种；
 * 2. 解压后做完整性校验（final.mdl 大小、Gr.fst 是否存在），
 *    不合格就清空重解，避免半截目录被永久复用；
 * 3. 每一处失败都带上具体原因（阶段 + 异常类 + 消息），
 *    经 asrEvent 写进 Dart 侧的运行日志 —— 下次有问题一眼能看出来；
 * 4. 解压过程回报进度，UI 不再长时间停在「正在准备模型」。
 */
object OfflineAsr {

    private const val ASSET_ZIP = "vosk-model-zh.zip"
    private const val TARGET_DIR = "vosk-zh"
    private const val SAMPLE_RATE = 16000

    @Volatile private var model: Model? = null
    @Volatile private var recognizer: Recognizer? = null
    @Volatile private var running = false

    /** 正在解压/加载模型：防止连点两次并发准备 */
    @Volatile private var preparing = false

    @Volatile private var audioThread: Thread? = null
    @Volatile private var record: AudioRecord? = null

    /** 事件回调：type = detail / progress / ready / partial / result / error / end */
    @Volatile private var emit: ((String, String, Int) -> Unit)? = null

    /** 模型准备结果：ok=false 时 detail 就是人话的失败原因 */
    private class Prep(val ok: Boolean, val root: File?, val detail: String)

    // ------------------------------------------------------------ 对外接口

    /** APK 里是否带了模型（CI 没下到模型时为 false，前端据此降级） */
    @JvmStatic
    fun hasModel(context: Context): Boolean {
        return try {
            context.assets.open(ASSET_ZIP).close()
            true
        } catch (_: Throwable) {
            // 也允许已经解压过的情况（assets 被裁剪但本地还在）
            modelRoot(context) != null
        }
    }

    @JvmStatic
    fun isRunning(): Boolean = running

    /** 已解压模型占用的字节数（设置页「清理」入口显示用） */
    @JvmStatic
    fun modelBytes(context: Context): Long {
        val base = File(context.filesDir, TARGET_DIR)
        if (!base.exists()) return 0L
        return base.walkBottomUp()
            .filter { it.isFile }
            .sumOf { it.length() }
    }

    /**
     * 删除已解压的离线模型，释放空间（约 70MB）。
     *
     * 音频与模型都只用于「本地识别」；只用在线识别时这份数据是纯占用。
     * 删掉后如果哪天又需要本地识别，会自动重新从 assets 解压（慢 2–5 秒）。
     */
    @JvmStatic
    fun clearModel(context: Context) {
        cleanup()
        model = null
        runCatching { File(context.filesDir, TARGET_DIR).deleteRecursively() }
    }

    @JvmStatic
    fun isPreparing(): Boolean = preparing

    /**
     * 开始识别。**会阻塞（首次解压+加载 2–6 秒），调用方必须在后台线程。**
     *
     * 返回 true 表示已经开始收音；失败时通过 onEvent("error", 原因, code)
     * 把**具体原因**交给上层，code 仅用于分类：
     * 1=模型不可用 2=识别器创建失败 9=其它
     */
    @JvmStatic
    fun start(context: Context, onEvent: (String, String, Int) -> Unit): Boolean {
        if (running || preparing) return false
        emit = onEvent
        preparing = true
        try {
            val prep = ensureModel(context)
            onEvent("detail", prep.detail, 0)
            val root = prep.root
            if (!prep.ok || root == null) {
                onEvent("error", prep.detail, 1)
                return false
            }

            val rec = try {
                Recognizer(model!!, SAMPLE_RATE.toFloat())
            } catch (e: Throwable) {
                onEvent(
                    "error",
                    "识别器创建失败 ${e.javaClass.simpleName}: ${e.message}",
                    2,
                )
                return false
            }
            recognizer = rec
            startAudioLoop(rec)
            running = true
            onEvent("ready", "", 0)
            return true
        } catch (e: Throwable) {
            onEvent("error", "启动异常 ${e.javaClass.simpleName}: ${e.message}", 9)
            return false
        } finally {
            preparing = false
        }
    }

    @JvmStatic
    fun stop() {
        val wasRunning = running
        cleanup()
        if (wasRunning) emit?.invoke("end", "", 0)
    }

    // ------------------------------------------------------------ 模型准备

    private fun ensureModel(context: Context): Prep {
        model?.let { return Prep(true, null, "模型已在内存") }

        // 1) 已有解压结果 → 校验后直接用
        val existing = modelRoot(context)
        if (existing != null) {
            val bad = validate(existing)
            if (bad == null) {
                val p = load(existing, "复用已解压模型")
                if (p.ok) return p
                // 目录看着完整、Vosk 却加载不了：多半是上次解压到一半被
                // 打断，某个文件是坏的（校验只查得到缺失/过小）。
                // 清空重解一次再试，仍失败才把原因交给用户。
                runCatching { File(context.filesDir, TARGET_DIR).deleteRecursively() }
                return extractAndLoad(context, "${p.detail}；已清空重解")
            }
            // 目录在但内容不完整（上次解压中断 / 资产被裁）→ 清空重来
            runCatching { File(context.filesDir, TARGET_DIR).deleteRecursively() }
            return extractAndLoad(context, "上次解压不完整（$bad），已清理重来")
        }

        // 2) 首次解压
        return extractAndLoad(context, null)
    }

    private fun extractAndLoad(context: Context, prefix: String?): Prep {
        val ex = extract(context)
        val merged = listOfNotNull(prefix, ex.detail).joinToString("；")
        if (!ex.ok || ex.root == null) {
            return Prep(false, null, merged)
        }
        return load(ex.root, merged)
    }

    private fun load(root: File, prefix: String): Prep {
        return try {
            model = Model(root.absolutePath)
            Prep(true, root, "$prefix；模型加载成功 root=${root.name}")
        } catch (e: Throwable) {
            model = null
            Prep(
                false,
                null,
                "$prefix；模型加载失败 ${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    // ------------------------------------------------------------ 解压

    private fun extract(context: Context): Prep {
        val base = File(context.filesDir, TARGET_DIR)
        runCatching { base.deleteRecursively() }
        if (!base.mkdirs() && !base.isDirectory) {
            return Prep(false, null, "无法创建模型目录 ${base.absolutePath}")
        }

        var files = 0
        var bytes = 0L
        var lastReportedMb = -1L

        try {
            context.assets.open(ASSET_ZIP).use { raw ->
                BufferedInputStream(raw, 128 * 1024).use { buffered ->
                    ZipInputStream(buffered).use { zis ->
                        val buf = ByteArray(128 * 1024)
                        while (true) {
                            val entry = zis.nextEntry ?: break
                            val out = File(base, entry.name)
                            // 防 zip slip：解压路径必须落在 base 内
                            if (!out.canonicalPath.startsWith(base.canonicalPath)) {
                                continue
                            }
                            if (entry.isDirectory) {
                                out.mkdirs()
                            } else {
                                out.parentFile?.mkdirs()
                                out.outputStream().use { os ->
                                    while (true) {
                                        val n = zis.read(buf)
                                        if (n <= 0) break
                                        os.write(buf, 0, n)
                                        bytes += n
                                    }
                                }
                                files++
                                val mb = bytes / (1024 * 1024)
                                if (mb - lastReportedMb >= 8) {
                                    lastReportedMb = mb
                                    emit?.invoke("progress", "已解压 ${mb}MB", 0)
                                }
                            }
                        }
                    }
                }
            }
        } catch (e: Throwable) {
            return Prep(
                false,
                null,
                "解压失败 ${e.javaClass.simpleName}: ${e.message}" +
                    "（已写 ${bytes / 1048576}MB / $files 个文件）",
            )
        }

        val root = modelRoot(context) ?: return Prep(
            false,
            null,
            "解压完成但找不到模型根目录（$files 个文件 / ${bytes / 1048576}MB）",
        )
        val bad = validate(root)
        if (bad != null) {
            return Prep(
                false,
                null,
                "解压后校验失败：$bad（$files 个文件 / ${bytes / 1048576}MB）",
            )
        }
        return Prep(true, root, "解压 $files 个文件 / ${bytes / 1048576}MB → ${root.name}")
    }

    /**
     * 找模型根目录。
     *
     * 必须同时兼容两种布局：
     * - 扁平（vosk-model-small-* 系列）：`final.mdl`、`Gr.fst` 直接在根；
     * - 旧 Kaldi：`am/final.mdl` + `conf/`。
     */
    private fun modelRoot(context: Context): File? {
        val base = File(context.filesDir, TARGET_DIR)
        if (!base.isDirectory) return null
        return findRoot(base, 0)
    }

    private fun findRoot(dir: File, depth: Int): File? {
        if (depth > 3) return null
        if (isModelDir(dir)) return dir
        val children = dir.listFiles() ?: return null
        for (f in children) {
            if (f.isDirectory) findRoot(f, depth + 1)?.let { return it }
        }
        return null
    }

    private fun isModelDir(dir: File): Boolean {
        if (File(dir, "final.mdl").isFile) return true
        if (File(dir, "am/final.mdl").isFile) return true
        return false
    }

    /** 完整性校验：缺文件就别交给 Vosk（否则只会得到一句无信息的失败） */
    private fun validate(root: File): String? {
        val mdl = when {
            File(root, "final.mdl").isFile -> File(root, "final.mdl")
            File(root, "am/final.mdl").isFile -> File(root, "am/final.mdl")
            else -> return "缺少 final.mdl"
        }
        if (mdl.length() < 1_000_000L) {
            return "final.mdl 只有 ${mdl.length()} 字节（应约 13MB，解压不完整）"
        }
        val graphOk = listOf("Gr.fst", "graph/Gr.fst").any { File(root, it).isFile }
        if (!graphOk) return "缺少 Gr.fst"
        return null
    }

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
                    emit?.invoke("error", "麦克风初始化失败（被其它应用占用？）", 3)
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
                        emit?.invoke("error", "识别中断 ${e.javaClass.simpleName}: ${e.message}", 4)
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
                emit?.invoke("error", "录音异常 ${e.javaClass.simpleName}: ${e.message}", 5)
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
}
