package com.medreminder.med_reminder

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream
import kotlin.math.abs

/**
 * 在线识别用的「录一句」录音器
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么另写一个（不复用 OfflineAsr 的采集循环）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 离线（Vosk）是「边说边识别」，音频流直接喂给识别器，不需要缓存；
 * 在线（腾讯云一句话识别）必须先拿到**完整的一段音频**再上传，
 * 所以这里要自己判断「用户说完了没有」，然后把整段 PCM 交回 Dart。
 *
 * 断句策略（老人说话慢，不能太急）：
 * - 检测到人声后，安静满 1.2 秒 → 认为说完了；
 * - 一直没检测到人声，6 秒后自动结束（避免一直占着麦克风）；
 * - 最长 15 秒强制结束（一句话识别的上限是 60 秒，我们用不到那么长）。
 */
object OnlineRecorder {

    private const val SAMPLE_RATE = 16000

    /**
     * 判定「有人在说话」的能量阈值（16bit PCM 的 RMS）
     *
     * V1.12.0 从 1100 降到 380，并改为**自适应**（见 noiseFloor）：
     * 用户日志里 11 次尝试有 8 次是「在线录音没听到人声 | 192512 字节」——
     * 录满 6 秒却没判定出人声。1100 对这台机器的麦克风增益来说太高了，
     * 而固定阈值在不同机型/不同距离下必然有一头不准。
     */
    private const val SPEECH_RMS_MIN = 380.0

    /** 说完之后的静音判定：1.2 秒太急，老人一句话中间会换气 */
    private const val SILENCE_MS = 2500L

    /** 一句都没说出来时的兜底时长 */
    private const val NO_SPEECH_MS = 10000L

    /** 单次录音上限（一句话识别上限 60 秒，我们不需要那么长） */
    private const val MAX_MS = 20000L

    @Volatile private var running = false
    private var thread: Thread? = null

    @JvmStatic
    fun isRecording(): Boolean = running

    @JvmStatic
    fun stop() {
        running = false
        try { thread?.interrupt() } catch (_: Exception) {}
        thread = null
    }

    /**
     * 录一句。
     *
     * @param onEvent 过程事件：listening / speech / silence（用于 UI 提示）
     * @param onDone  录完回调：(PCM 字节, 毫秒, 是否检测到人声, 峰值 RMS)
     */
    @JvmStatic
    fun record(
        context: Context,
        onEvent: (String) -> Unit,
        onDone: (ByteArray, Int, Boolean, Double) -> Unit,
        onError: (String) -> Unit,
    ) {
        if (running) {
            onError("上一次录音还没结束")
            return
        }
        running = true
        thread = Thread {
            var ar: AudioRecord? = null
            try {
                val minBuf = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                )
                val bufSize = if (minBuf > 0) maxOf(minBuf * 2, 4096) else 8192

                ar = AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufSize,
                )
                if (ar.state != AudioRecord.STATE_INITIALIZED) {
                    onError("麦克风打不开（可能被别的应用占用）")
                    return@Thread
                }

                ar.startRecording()
                onEvent("listening")

                val out = ByteArrayOutputStream()
                val buffer = ByteArray(bufSize)
                val startedAt = System.currentTimeMillis()
                var lastVoiceAt = startedAt
                var hasSpeech = false
                var peak = 0.0

                // 环境本底噪声：用开头 600ms 的均值估计，阈值 = 本底 × 2.2
                // （下限 380），这样安静房间和嘈杂环境都能用同一套逻辑
                var noiseSum = 0.0
                var noiseCount = 0

                while (running && !Thread.currentThread().isInterrupted) {
                    val n = ar.read(buffer, 0, buffer.size)
                    if (n <= 0) {
                        // 读出 0 字节时不要空转把 CPU 打满
                        try { Thread.sleep(20) } catch (_: InterruptedException) { break }
                        continue
                    }
                    out.write(buffer, 0, n)

                    val now = System.currentTimeMillis()
                    val total = now - startedAt
                    val level = rms(buffer, n)
                    if (level > peak) peak = level

                    if (!hasSpeech && total < 600) {
                        noiseSum += level
                        noiseCount++
                    }
                    val floor = if (noiseCount > 0) noiseSum / noiseCount else 0.0
                    val threshold = maxOf(SPEECH_RMS_MIN, floor * 2.2)

                    if (level > threshold) {
                        lastVoiceAt = now
                        if (!hasSpeech) {
                            hasSpeech = true
                            onEvent("speech")
                        }
                    }

                    val silent = now - lastVoiceAt
                    if (hasSpeech && silent > SILENCE_MS) {
                        onEvent("silence")
                        break
                    }
                    if (!hasSpeech && total > NO_SPEECH_MS) break
                    if (total > MAX_MS) break
                }

                val bytes = out.toByteArray()
                val ms = (System.currentTimeMillis() - startedAt).toInt()
                // 先落 running 再回调：Dart 收到 onDone 后可能立刻发起
                // 下一次录音（回落离线），此时不能还被判成「正在录音」
                running = false
                onDone(bytes, ms, hasSpeech, peak)
            } catch (e: Throwable) {
                onError("录音出错 ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                running = false
                try { ar?.stop() } catch (_: Exception) {}
                try { ar?.release() } catch (_: Exception) {}
            }
        }.also { it.isDaemon = true; it.start() }
    }

    /** 16bit 小端 PCM 的均方根，用来判断「有没有人在说话」 */
    private fun rms(buffer: ByteArray, len: Int): Double {
        if (len < 2) return 0.0
        var sum = 0.0
        var i = 0
        // 每 4 个采样取 1 个就够判断能量，省点 CPU
        while (i + 1 < len) {
            val s = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)).toShort()
            val v = abs(s.toInt()).toDouble()
            sum += v * v
            i += 8
        }
        val count = maxOf(1, len / 8)
        return kotlin.math.sqrt(sum / count)
    }
}
