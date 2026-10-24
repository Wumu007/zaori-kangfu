package com.medreminder.med_reminder

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 入口 Activity + 原生能力桥。
 *
 * V1.5.0 起承担四件事（都经 MethodChannel `med_reminder/native` 暴露给 Dart）：
 *
 * 1. showSystemSpeechDialog —— 系统「语音输入」对话框。
 *    speech_to_text 插件的服务连接方式在 vivo/iQOO 上不可靠（V1.3/V1.4 两版
 *    真机均无反应），而 ACTION_RECOGNIZE_SPEECH 是所有语音引擎都实现的标准
 *    Intent，微信语音转文字也走这条路 —— 作为插件路径失败后的兜底。
 *
 * 2. ringStart / ringStop —— 循环响铃。
 *    通知铃声只播一遍是系统行为，想「响到用户处理为止」必须自己播。
 *    MediaPlayer 循环 + Vibrator 循环波形，音量走闹钟流。
 *
 * 3. keepScreenOn —— 响铃页常亮。
 *
 * 4. 电池优化白名单 —— vivo/小米等 ROM 会冻结后台应用并取消第三方闹钟，
 *    这是「后台/锁屏收不到提醒」的第一解法。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "med_reminder/native"
        private const val REQ_SPEECH = 40001

        /** 原生通知带过来的服药 payload（Dart 侧 takePendingPayload 取用） */
        const val EXTRA_PAYLOAD = "med_payload"

        @Volatile internal var pendingPayload: String? = null

        // ═══════════════════════════════════════════════════════════════
        // 响铃状态放伴生对象：
        // ActionBroadcastReceiver（通知栏按钮）在进程未拉起 UI 时也能收到
        // 点击，需要在这里直接把铃声停掉。
        // ═══════════════════════════════════════════════════════════════

        @Volatile private var player: MediaPlayer? = null
        @Volatile private var vibrator: Vibrator? = null

        /** 停止响铃。任何地方（Activity / Dart / 通知按钮回调）都可安全调用 */
        @JvmStatic fun ringStop() {
            try { player?.stop(); player?.release() } catch (_: Exception) {}
            player = null
            try { vibrator?.cancel() } catch (_: Exception) {}
            vibrator = null
        }

        /**
         * 开始循环响铃。
         *
         * ═══════════════════════════════════════════════════════════
         * V1.7.0 修复「点闹钟后黑屏」（用户实测反馈第 2 条之二）
         * ═══════════════════════════════════════════════════════════
         *
         * 旧实现用 `MediaPlayer.prepare()` —— 那是**同步阻塞**调用，
         * 而且是在主线程（UI 线程）上调的。冷启动点通知时，Flutter
         * 引擎还在初始化，主线程又被 prepare 卡住读铃声文件，界面就
         * 停在深色底上不动，看起来就是「黑屏」，严重时要杀进程。
         *
         * 现在改用 `prepareAsync()` + `setOnPreparedListener`：
         * 主线程立刻返回，铃声在后台解码好再响，UI 不会被堵。
         */
        @JvmStatic fun ringStart(context: Context) = ringStartImpl(context)

        private fun ringStartImpl(context: Context) {
            if (player != null) return // 已经在响，避免叠加
            ringStop()

            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: return
            try {
                val p = MediaPlayer()
                p.setDataSource(context, uri)
                p.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                p.isLooping = true
                p.setOnPreparedListener { mp ->
                    try {
                        mp.start()
                    } catch (_: Exception) {}
                }
                p.setOnErrorListener { mp, _, _ ->
                    try { mp.release() } catch (_: Exception) {}
                    if (player === mp) player = null
                    true
                }
                player = p
                // 关键：异步准备，不阻塞 UI 线程
                p.prepareAsync()
            } catch (_: Exception) {
                player = null
            }

            // 震动：长-短-长循环（与通知渠道节奏一致）
            try {
                val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                        as android.os.VibratorManager
                    vm.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v.vibrate(
                        VibrationEffect.createWaveform(
                            longArrayOf(0, 800, 400, 800, 400, 800), 0
                        )
                    )
                } else {
                    @Suppress("DEPRECATION")
                    v.vibrate(longArrayOf(0, 800, 400, 800, 400, 800), 0)
                }
                vibrator = v
            } catch (_: Exception) {
                vibrator = null
            }
        }

        /**
         * 启动后台守护前台服务。
         *
         * 只能在 App 处于前台时调用（Android 12+ 不允许后台启动前台服务），
         * 所以调用点是 main.dart 启动流程与页面回前台时。
         */
        /**
         * 启动后台守护服务。
         *
         * 返回 true 表示「启动请求已发出」。服务是异步起来的，这里立刻
         * 查 running 一定是 false —— V1.7.0 的日志因此误报「启动失败」。
         * 真实状态请用 isGuardRunning。
         */
        @JvmStatic fun startGuard(context: Context): Boolean {
            return try {
                val i = Intent(context, ReminderGuardService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(i)
                } else {
                    context.startService(i)
                }
                true
            } catch (e: Exception) {
                android.util.Log.e("MedReminder", "startGuard failed: $e")
                false
            }
        }

        // ---- V1.8.0 新增：悬浮窗 / 后台拉界面 / 语音设置 ----

        /** 是否已获得「显示在其他应用上层」权限（后台弹界面的前提） */
        @JvmStatic fun canDrawOverlays(context: Context): Boolean {
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    Settings.canDrawOverlays(context)
                } else {
                    true
                }
            } catch (_: Exception) {
                false
            }
        }

        /** 跳系统页申请悬浮窗权限 */
        @JvmStatic fun requestOverlayPermission(context: Context) {
            try {
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                        data = Uri.parse("package:${context.packageName}")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                )
            } catch (_: Exception) {
                try {
                    context.startActivity(
                        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                } catch (_: Exception) {}
            }
        }

        /** 打开系统「语音输入」设置页（诊断到无服务时引导用户去启用） */
        @JvmStatic fun openVoiceInputSettings(context: Context) {
            val candidates = listOf(
                Settings.ACTION_VOICE_INPUT_SETTINGS,
                "com.android.settings.TTS_SETTINGS",
                Settings.ACTION_SETTINGS,
            )
            for (action in candidates) {
                try {
                    context.startActivity(
                        Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    return
                } catch (_: Exception) {}
            }
        }

        /**
         * 从后台直接拉起响铃页（GuardAlarmReceiver 调用）。
         *
         * 前提是有悬浮窗权限；没有时 startActivity 会被系统吞掉，
         * 用户仍会收到通知（保底）。
         */
        @JvmStatic fun launchRinging(context: Context, payload: String) {
            try {
                pendingPayload = payload
                val i = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP,
                    )
                    putExtra(EXTRA_PAYLOAD, payload)
                }
                context.startActivity(i)
            } catch (_: Exception) {}
        }

        @JvmStatic fun stopGuard(context: Context) {
            try {
                context.stopService(Intent(context, ReminderGuardService::class.java))
            } catch (_: Exception) {}
        }

        /**
         * 取出「原生通知点开时带过来的 payload」。
         *
         * 第二通道（GuardAlarm）发的通知不是 flutter_local_notifications
         * 发的，因此它的点击不会出现在 getNotificationAppLaunchDetails 里，
         * 只能通过 Activity 的 Intent extra 传过来，由 Dart 主动来取。
         */
        @JvmStatic fun takePendingPayload(): String? {
            val v = pendingPayload
            pendingPayload = null
            return v
        }
    }

    private var pendingSpeech: MethodChannel.Result? = null

    /** 原生语音识别器（第三条路径：插件 → 原生识别器 → 系统对话框） */
    private var nativeAsr: SpeechRecognizer? = null

    /** 保存 channel，用于把识别结果主动推回 Dart */
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "showSystemSpeechDialog" -> showSystemSpeechDialog(
                        call.argument<String>("language") ?: "zh-CN",
                        result,
                    )
                    "speechServices" -> result.success(listSpeechServices())
                    "ringStart" -> { startRinging(this); result.success(true) }
                    "ringStop" -> { ringStop(); result.success(true) }
                    "isRinging" -> result.success(player != null)
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" ->
                        requestIgnoreBatteryOptimizations(result)
                    "startGuard" -> result.success(startGuard(this))
                    "canDrawOverlays" -> result.success(canDrawOverlays(this))
                    "requestOverlayPermission" -> {
                        requestOverlayPermission(this)
                        result.success(true)
                    }
                    "openVoiceInputSettings" -> {
                        openVoiceInputSettings(this)
                        result.success(true)
                    }
                    "setTestAlarm" -> {
                        val seconds = call.argument<Int>("seconds") ?: 10
                        val id = call.argument<Int>("id") ?: 990001
                        val payload = call.argument<String>("payload") ?: ""
                        val title = call.argument<String>("title") ?: "测试提醒"
                        val body = call.argument<String>("body") ?: ""
                        GuardAlarm.setOneShot(
                            this,
                            id,
                            System.currentTimeMillis() + seconds * 1000L,
                            title,
                            body,
                            payload,
                            title,
                        )
                        result.success(true)
                    }
                    "stopGuard" -> {
                        stopGuard(this)
                        result.success(true)
                    }
                    "isGuardRunning" -> result.success(ReminderGuardService.running)
                    "startNativeAsr" -> startNativeAsr(
                        call.argument<String>("language") ?: "zh-CN",
                        result,
                    )
                    "stopNativeAsr" -> { stopNativeAsr(); result.success(true) }
                    "nativeAsrAvailable" -> result.success(
                        try { SpeechRecognizer.isRecognitionAvailable(this) } catch (e: Exception) { false }
                    )
                    "setGuardSchedule" -> {
                        val json = call.argument<String>("json") ?: "[]"
                        GuardAlarm.setSchedule(this, json)
                        result.success(true)
                    }
                    "takePendingPayload" -> result.success(takePendingPayload())
                    else -> result.notImplemented()
                }
            }
    }

    // ═══════════════════════════════════════════════════════════════
    // 0. 原生语音识别器（静默识别，不弹对话框）
    // ═══════════════════════════════════════════════════════════════
    //
    // speech_to_text 插件走的是 createSpeechRecognizer(pluginContext)
    // + 它自己的回调封装，在 iQOO 上连续三版都不工作。这里用官方
    // SpeechRecognizer API 自己实现一遍，绕开插件封装。
    // 结果通过 MethodChannel 的 "asrEvent" 主动回传 Dart：
    //   {type: ready|speaking|partial|result|error|end, text, code}

    private fun startNativeAsr(language: String, result: MethodChannel.Result) {
        try {
            if (!SpeechRecognizer.isRecognitionAvailable(this)) {
                result.error("no_engine", "no speech recognition service", null)
                return
            }
            stopNativeAsr()
            val rec = SpeechRecognizer.createSpeechRecognizer(this)
            rec.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = emitAsr("ready", "")
                override fun onBeginningOfSpeech() = emitAsr("speaking", "")
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() = emitAsr("endOfSpeech", "")

                override fun onError(error: Int) {
                    emitAsr("error", "", error)
                }

                override fun onResults(results: Bundle?) {
                    val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    emitAsr("result", list?.firstOrNull() ?: "")
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val list = partialResults?.getStringArrayList(
                        SpeechRecognizer.RESULTS_RECOGNITION
                    )
                    val text = list?.firstOrNull() ?: ""
                    if (text.isNotEmpty()) emitAsr("partial", text)
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                )
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
                // 老人说话慢，给足静音等待时间（3 秒才判定说完了）
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                    3000L,
                )
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                    3000L,
                )
            }
            nativeAsr = rec
            rec.startListening(intent)
            result.success(true)
        } catch (e: Exception) {
            nativeAsr = null
            result.error("start_failed", e.message, null)
        }
    }

    private fun stopNativeAsr() {
        try { nativeAsr?.stopListening() } catch (_: Exception) {}
        try { nativeAsr?.cancel() } catch (_: Exception) {}
        try { nativeAsr?.destroy() } catch (_: Exception) {}
        nativeAsr = null
    }

    /** 把识别事件推给 Dart */
    private fun emitAsr(type: String, text: String, code: Int = 0) {
        runOnUiThread {
            try {
                channel?.invokeMethod(
                    "asrEvent",
                    mapOf("type" to type, "text" to text, "code" to code),
                )
            } catch (_: Exception) {}
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // 1. 系统语音对话框
    // ═══════════════════════════════════════════════════════════════

    private fun showSystemSpeechDialog(language: String, result: MethodChannel.Result) {
        // 一次只允许一个等待中的对话框请求
        if (pendingSpeech != null) {
            result.success(null)
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(RecognizerIntent.EXTRA_PROMPT, "请说出药品和服用方法")
        }
        // ═══════════════════════════════════════════════════════════
        // V1.8.0：不再用 resolveActivity 预判断
        // ═══════════════════════════════════════════════════════════
        //
        // 用户日志显示「路径C 返回 | 无文字」「系统语音服务=[]」——
        // 根因是 Android 11+ 的包可见性：manifest 没声明
        // android.speech.action.RECOGNIZE_SPEECH 时，resolveActivity()
        // 一律返回 null，于是这里直接报 no_engine，对话框从未启动。
        // 现在直接尝试启动，只在真的抛 ActivityNotFoundException 时才
        // 认定「没有语音服务」；manifest 那边也补了 queries。
        pendingSpeech = result
        try {
            startActivityForResult(intent, REQ_SPEECH)
        } catch (e: android.content.ActivityNotFoundException) {
            pendingSpeech = null
            result.error("no_engine", "no activity for RECOGNIZE_SPEECH", null)
        } catch (e: Exception) {
            pendingSpeech = null
            result.error("start_failed", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_SPEECH) return
        val r = pendingSpeech
        pendingSpeech = null
        if (r == null) return
        if (resultCode == Activity.RESULT_OK && data != null) {
            val text = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            r.success(text?.firstOrNull())
        } else {
            // 用户取消 / 引擎内部失败：返回 null，Dart 侧按「没拿到文字」处理
            r.success(null)
        }
    }

    /** 系统里有哪些语音识别服务（诊断页显示，帮用户确认设备到底有没有） */
    private fun listSpeechServices(): List<String> {
        val out = mutableListOf<String>()
        try {
            val pm = packageManager
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            val resolved = pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            for (info in resolved) {
                // ResolveInfo 没有 packageName 字段：标签取不到时退到
                // activityInfo.packageName / resolvePackageName
                val pkg = info.activityInfo?.packageName ?: info.resolvePackageName
                out.add(info.loadLabel(pm)?.toString() ?: pkg ?: "unknown")
            }
        } catch (_: Exception) {}
        return out
    }

    // ═══════════════════════════════════════════════════════════════
    // 2. 循环响铃（铃声 + 震动都循环，直到 ringStop）
    // ═══════════════════════════════════════════════════════════════

    private fun startRinging(context: Context) = ringStart(context)

    // ═══════════════════════════════════════════════════════════════
    // 3. 电池优化白名单
    // ═══════════════════════════════════════════════════════════════

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Exception) {
            false
        }
    }

    private fun requestIgnoreBatteryOptimizations(result: MethodChannel.Result) {
        try {
            if (isIgnoringBatteryOptimizations()) {
                result.success(true)
                return
            }
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
            // 用户在系统对话框里的选择无法同步拿回（onActivityResult 对该
            // action 不保证回调），返回 true 表示「已拉起」，最终状态由
            // Dart 侧回来后重新查询 isIgnoringBatteryOptimizations。
            result.success(true)
        } catch (e: Exception) {
            // 个别 ROM 禁掉了这个入口，退到电池优化设置列表页
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                result.success(true)
            } catch (_: Exception) {
                result.error("failed", e.message, null)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // 响铃页需要：锁屏上也直接亮出界面
    // ═══════════════════════════════════════════════════════════════

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 冷启动直接来自通知点击时，锁屏状态也要能显示
        // （showWhenLocked/turnScreenOn 需 API 27+；minSdk 23 的老设备由
        //   fullScreenIntent 的系统全屏行为兜底）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        capturePayload(intent)
    }

    /**
     * App 已在前台/后台时被原生通知唤起（singleTop）→ 从这里拿 payload。
     *
     * 第二通道（GuardAlarm）发的通知不是 flutter_local_notifications 发的，
     * 它的点击不会走 fln 的 getNotificationAppLaunchDetails，只能靠 Intent。
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        capturePayload(intent)
        // 让 Dart 侧知道有新 payload 可取（Dart 收到后自行 push 响铃页）
        try {
            channel?.invokeMethod("ringingPayload", null)
        } catch (_: Exception) {}
    }

    private fun capturePayload(intent: Intent?) {
        val p = intent?.getStringExtra(EXTRA_PAYLOAD)
        if (!p.isNullOrEmpty()) {
            pendingPayload = p
        }
    }
}
