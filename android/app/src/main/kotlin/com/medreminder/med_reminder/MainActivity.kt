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

        /**
         * 当前存活的 Activity（V1.14.0）。
         * 响铃服务的通知按钮要靠它判断「Dart 在不在跑」。
         */
        @Volatile
        var instance: MainActivity? = null
            private set

        /** Activity 是否正处在前台可见（响铃服务据此决定要不要补拉起） */
        @Volatile
        var isVisible: Boolean = false
        private const val CHANNEL = "med_reminder/native"
        private const val REQ_SPEECH = 40001

        /** 原生通知带过来的服药 payload（Dart 侧 takePendingPayload 取用） */
        const val EXTRA_PAYLOAD = "med_payload"

        /** 用户点了通知按钮时带的动作：taken / snooze / skip */
        const val EXTRA_ACTION = "med_action"

        /**
         * 当前正在响铃的那条提醒的 payload（V1.17.1）
         *
         * 用来判断「主路径（闹钟直接拉起界面）是不是已经处理过了」。
         * 2 秒后的兜底广播起 RingingService 时，若这里的 payload 与广播
         * 带的一致，说明界面上已经在响，不必再 startActivity 拉一次 ——
         * 否则响铃页会叠两层，用户返回要按两次（V1.15.0 修过的老问题）。
         */
        @Volatile internal var ringingPayload: String? = null

        @Volatile internal var pendingPayload: String? = null

        // ═══════════════════════════════════════════════════════════════
        // 响铃状态放伴生对象：
        // ActionBroadcastReceiver（通知栏按钮）在进程未拉起 UI 时也能收到
        // 点击，需要在这里直接把铃声停掉。
        // ═══════════════════════════════════════════════════════════════

        @Volatile private var player: MediaPlayer? = null
        @Volatile private var vibrator: Vibrator? = null

        /**
         * 响铃代号（V1.17.2）
         *
         * prepareAsync 是异步的：点下「已处理」的那一刻，播放器往往还在
         * **准备中**。这时停掉，准备好的回调照样会来。每次停铃把代号 +1，
         * 回调里对不上就说明这次响铃已被取消，直接释放、绝不出声。
         */
        @Volatile private var ringGeneration: Int = 0

        /**
         * 停止响铃。任何地方（Activity / Dart / 通知按钮回调）都可安全调用
         *
         * ═══════════════════════════════════════════════════════════
         * V1.17.2：这里原来一行吞掉了全部收尾动作（用户反馈「点了已处理
         * 铃声还在响、只有再点一次通知才停」）
         * ═══════════════════════════════════════════════════════════
         *
         * 旧代码是：
         *     try { player?.stop(); player?.release() } catch (_: Exception) {}
         *
         * MediaPlayer 在 **Preparing 状态** 调 stop() 会抛
         * IllegalStateException。它和 release() 写在同一个 try 里，
         * 异常一抛就直接跳到 catch —— **release() 从未执行**。
         *
         * 后果是三个一起发生：
         * 1. 播放器没被释放，prepareAsync 完成后照样 start() 出声；
         * 2. player 变量已被置空，**再没有任何句柄能停掉这个声音**；
         * 3. 用户每点一次通知就多一个这样的幽灵播放器，越点越响。
         *
         * 现在：代号先作废在途回调，listener 全部摘掉，stop 与 release
         * 各自独立 try，任何一个失败都不影响另一个执行。
         */
        @JvmStatic fun ringStop() {
            ringGeneration++
            val p = player
            player = null
            if (p != null) {
                try { p.setOnPreparedListener(null) } catch (_: Exception) {}
                try { p.setOnErrorListener(null) } catch (_: Exception) {}
                try { p.setOnCompletionListener(null) } catch (_: Exception) {}
                // 两行必须分开：stop() 在 Preparing 状态抛异常时，
                // 不能把 release() 一起带走
                try { if (p.isPlaying) p.stop() } catch (_: Exception) {}
                try { p.release() } catch (_: Exception) {}
            }
            try { vibrator?.cancel() } catch (_: Exception) {}
            vibrator = null
            ringingPayload = null
            NativeLog.log("MainActivity", "ringStop 执行（gen=$ringGeneration）")
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
        @JvmStatic fun ringStart(context: Context) = ringStartImpl(context, null)

        /** 带 payload 的版本：用于让 RingingService 知道「现在响的是哪一条」 */
        @JvmStatic fun ringStart(context: Context, payload: String) = ringStartImpl(context, payload)

        private fun ringStartImpl(context: Context, payload: String?) {
            if (player != null) {
                // 已经在响：只补记 payload，不重复播
                if (payload != null) ringingPayload = payload
                return
            }
            // 清理上一次可能残留的播放器（这里会顺手把 ringingPayload 清空，
            // 所以真正的赋值必须放在它之后）
            ringStop()
            // 记下这次响铃的代号：prepare 期间若被 ringStop 打断，
            // 回调里的代号就对不上，不再出声
            val gen = ringGeneration
            if (payload != null) ringingPayload = payload

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
                    // 准备期间已经被停掉（用户点了「已处理」/离开页面）：
                    // 绝不能 start，否则就是那个「停不掉的幽灵铃声」
                    if (gen != ringGeneration) {
                        try { mp.release() } catch (_: Exception) {}
                    } else {
                        try { mp.start() } catch (_: Exception) {}
                    }
                }
                p.setOnErrorListener { mp, _, _ ->
                    try { mp.release() } catch (_: Exception) {}
                    if (player === mp) player = null
                    true
                }
                player = p
                // 关键：异步准备，不阻塞 UI 线程
                p.prepareAsync()
                NativeLog.log("MainActivity", "ringStart 已发起（gen=$gen）")
            } catch (e: Exception) {
                player = null
                NativeLog.log("MainActivity", "ringStart 失败: ${e.message}")
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
            launchActivity(context, payload, null)
        }

        /** 用户点了通知上的按钮 → 带着动作把 App 拉起来，由 Dart 落库 */
        @JvmStatic fun launchWithAction(context: Context, payload: String, action: String) {
            launchActivity(context, payload, action)
        }

        /**
         * 从后台拉起 MainActivity。
         *
         * ═══════════════════════════════════════════════════════════
         * V1.14.0：这里以前把所有异常都吞了，是这次排查困难的根源
         * ═══════════════════════════════════════════════════════════
         *
         * 用户日志里到点那一刻「一条记录都没有」—— 说明界面从未拉起，
         * 但代码里没有任何痕迹。现在每一步都记进 native_ring.log：
         * 悬浮窗有没有、startActivity 抛了什么、Activity 有没有活着的实例。
         */
        @JvmStatic
        fun launchActivity(context: Context, payload: String, action: String?) {
            pendingPayload = payload
            try {
                val i = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP,
                    )
                    putExtra(EXTRA_PAYLOAD, payload)
                    if (action != null) putExtra(EXTRA_ACTION, action)
                }
                context.startActivity(i)
                NativeLog.log(
                    "launchRinging",
                    "startActivity 成功 overlay=${canDrawOverlays(context)} " +
                        "alive=${instance != null} action=${action ?: "-"}",
                )
            } catch (e: Exception) {
                NativeLog.log(
                    "launchRinging",
                    "startActivity 被拒 ${e.javaClass.simpleName}: ${e.message} " +
                        "overlay=${canDrawOverlays(context)}",
                )
            }
        }

        /** Android 14+ 的「全屏通知」授权状态 */
        @JvmStatic
        fun canUseFullScreenIntent(context: Context): Boolean {
            return try {
                if (Build.VERSION.SDK_INT >= 34) {
                    val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                        as android.app.NotificationManager
                    nm.canUseFullScreenIntent()
                } else {
                    true
                }
            } catch (_: Exception) {
                false
            }
        }

        /**
         * 跳到「允许全屏通知」的系统页。
         *
         * Android 14 起，非闹钟/通话类应用的 USE_FULL_SCREEN_INTENT 会被
         * 系统收回 —— 没有它，锁屏时通知只能待在通知栏，不会自动弹界面。
         * 用药提醒属于「时间敏感」，值得让用户手动开这一项。
         */
        @JvmStatic
        fun requestFullScreenIntentPermission(context: Context) {
            try {
                if (Build.VERSION.SDK_INT >= 34) {
                    context.startActivity(
                        Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                            data = Uri.parse("package:${context.packageName}")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                    )
                    return
                }
            } catch (_: Exception) {}
            // 老系统或 ROM 没有该页面：退到应用详情页
            try {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:${context.packageName}")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                )
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

        // ═══════════════════════════════════════════════════════════════
        // 「这条提醒已经处理过了」标记（V1.17.2）
        // ═══════════════════════════════════════════════════════════════
        //
        // 用户点了「已处理」之后，那条 ongoing 通知可能还没从通知栏消失
        //（ROM 有延迟，或者用户手快又点了一下）。再点时原生 onNewIntent
        // 会当成一次新的到点，又 ringStart —— 用户看到的就是
        //「只有再点一次这条消息才会停/才会又响」这种反直觉的行为。
        //
        // 处理动作发生时由 Dart 打一个标记，onNewIntent / onCreate 见到
        // 同一条就不再响。注意「稍后提醒」**不**打标记 —— 那条本来就要
        // 再叫一次。标记 3 天后自动过期，避免无限堆积。
        private const val PREFS_HANDLED = "ring_handled_v1"
        private const val HANDLED_TTL_MS = 3L * 24 * 3600 * 1000

        @JvmStatic
        fun markRingHandled(context: Context, payload: String) {
            if (payload.isEmpty()) return
            try {
                val sp = context.getSharedPreferences(PREFS_HANDLED, Context.MODE_PRIVATE)
                val now = System.currentTimeMillis()
                val e = sp.edit()
                for (k in sp.all.keys) {
                    val t = (sp.all[k] as? Long) ?: 0L
                    if (now - t > HANDLED_TTL_MS) e.remove(k)
                }
                e.putLong(payload, now)
                e.apply()
                NativeLog.log("MainActivity", "已标记处理 ${payload.take(40)}")
            } catch (_: Exception) {}
        }

        @JvmStatic
        fun isRingHandled(context: Context, payload: String): Boolean {
            return try {
                context.getSharedPreferences(PREFS_HANDLED, Context.MODE_PRIVATE)
                    .contains(payload)
            } catch (_: Exception) {
                false
            }
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
                    // ---- V1.14.0：全屏通知权限 / 响铃服务 / 原生日志 ----
                    "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent(this))
                    "requestFullScreenIntentPermission" -> {
                        requestFullScreenIntentPermission(this)
                        result.success(true)
                    }
                    "isRingingServiceActive" -> result.success(RingingService.active)
                    // 应用内自检触发时也走响铃服务：铃声/通知/唤醒锁一致，
                    // 不然「兜底」和「真闹钟」两套表现
                    "ringingServiceStart" -> {
                        val payload = call.argument<String>("payload") ?: ""
                        val title = call.argument<String>("title") ?: "该吃药了"
                        val body = call.argument<String>("body") ?: ""
                        val id = call.argument<Int>("id") ?: 990002
                        RingingService.start(this, id, title, body, payload)
                        result.success(true)
                    }
                    "ringingServiceStop" -> {
                        RingingService.stop(this, "Dart 请求")
                        result.success(true)
                    }
                    "readNativeLog" -> {
                        val text = NativeLog.read(this)
                        result.success(text)
                    }
                    "takePendingAction" -> result.success(NativeLog.takePendingAction(this))
                    // ---- V1.15.0：数据保险箱（卸载不丢） ----
                    "vaultSave" -> {
                        val json = call.argument<String>("json") ?: ""
                        result.success(VaultStore.save(this, json))
                    }
                    "vaultLoad" -> result.success(VaultStore.load(this))
                    "vaultPath" -> result.success(VaultStore.path(this))
                    "vaultExists" -> result.success(VaultStore.exists(this))
                    "vaultClear" -> result.success(VaultStore.clear(this))
                    "flushNativeLog" -> {
                        NativeLog.flush(this)
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
                    // ---- 离线识别（Vosk，自带模型）----
                    "offlineAsrHasModel" -> result.success(OfflineAsr.hasModel(this))
                    "offlineAsrPrepared" -> result.success(OfflineAsr.isRunning())
                    "startOfflineAsr" -> {
                        if (OfflineAsr.isRunning() || OfflineAsr.isPreparing()) {
                            // V1.10.0：上次还没收尾时不要静默返回 false ——
                            // 那会让 Dart 一直等到超时。这里主动回一条事件。
                            emitAsr("offline_error", "上一次语音还没结束", 6)
                            result.success(false)
                        } else {
                            // 模型首次要解压+加载（2–6 秒），放后台线程；
                            // 这里立刻返回 true，进度与结果通过 asrEvent 推送
                            Thread {
                                OfflineAsr.start(this) { type, text, code ->
                                    emitAsr("offline_$type", text, code)
                                }
                            }.start()
                            result.success(true)
                        }
                    }
                    "stopOfflineAsr" -> {
                        OfflineAsr.stop()
                        result.success(true)
                    }
                    "offlineModelBytes" -> result.success(OfflineAsr.modelBytes(this))
                    "clearOfflineModel" -> {
                        OfflineAsr.clearModel(this)
                        result.success(true)
                    }
                    // ---- 在线识别（腾讯云）：录一句 PCM 交回 Dart ----
                    "startOnlineRecord" -> {
                        OnlineRecorder.record(
                            this,
                            onEvent = { ev -> emitAsr("online_$ev", "", 0) },
                            onDone = { pcm, ms, hasSpeech, peak ->
                                runOnUiThread {
                                    try {
                                        channel?.invokeMethod(
                                            "onlineAudio",
                                            mapOf(
                                                "pcm" to pcm,
                                                "ms" to ms,
                                                "hasSpeech" to hasSpeech,
                                                "peak" to peak,
                                            ),
                                        )
                                    } catch (_: Exception) {}
                                }
                            },
                            onError = { msg ->
                                runOnUiThread {
                                    try {
                                        channel?.invokeMethod(
                                            "onlineAudio",
                                            mapOf("error" to msg),
                                        )
                                    } catch (_: Exception) {}
                                }
                            },
                        )
                        result.success(true)
                    }
                    "stopOnlineRecord" -> {
                        OnlineRecorder.stop()
                        result.success(true)
                    }
                    "nativeAsrAvailable" -> result.success(
                        try { SpeechRecognizer.isRecognitionAvailable(this) } catch (e: Exception) { false }
                    )
                    "setGuardSchedule" -> {
                        val json = call.argument<String>("json") ?: "[]"
                        GuardAlarm.setSchedule(this, json)
                        result.success(true)
                    }
                    "takePendingPayload" -> result.success(takePendingPayload())
                    // V1.17.2：处理完一条提醒后打标记，之后同一条再被点开不再响铃
                    "markRingHandled" -> {
                        markRingHandled(this, call.argument<String>("payload") ?: "")
                        result.success(true)
                    }
                    "isRingHandled" -> result.success(
                        isRingHandled(this, call.argument<String>("payload") ?: "")
                    )
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
        instance = this
        capturePayload(intent)
        val bootPayload = intent?.getStringExtra(EXTRA_PAYLOAD)
        NativeLog.log("MainActivity", "onCreate payload=${bootPayload?.take(40)}")

        // V1.17.0：闹钟的 PendingIntent 现在直接指向本 Activity。
        // 到这里说明就是被闹钟拉起来的 —— **立刻响铃**，不要等 Flutter
        // 引擎起来再响（那要 2–4 秒，用户会觉得"没响"）。
        if (!bootPayload.isNullOrEmpty()) {
            val boot = bootPayload!!
            if (isRingHandled(this, boot)) {
                // 处理过的提醒又被点开（通知还没消失时手快又点了一次）：
                // 只把 payload 交给 Dart 展示，不再出声
                NativeLog.log("MainActivity", "冷启动：这条已处理过，不响铃")
            } else {
                NativeLog.log("MainActivity", "由闹钟直接拉起，立即响铃")
                ringStart(this, boot)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        isVisible = true
    }

    override fun onPause() {
        isVisible = false
        super.onPause()
    }

    override fun onDestroy() {
        isVisible = false
        if (instance === this) instance = null
        super.onDestroy()
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

        // 带动作进来 = 用户在通知上点了「已服药 / 延后 / 跳过」。
        // 这时**不该**再进响铃页，否则用户刚做完决定又被弹一次。
        // 热启动被闹钟拉起：同样立刻响铃（还没进响铃页）
        val newPayload = intent.getStringExtra(EXTRA_PAYLOAD)
        if (newPayload != null && intent.getStringExtra(EXTRA_ACTION) == null) {
            if (isRingHandled(this, newPayload)) {
                NativeLog.log("MainActivity", "热启动：这条已处理过，不响铃")
            } else {
                NativeLog.log("MainActivity", "onNewIntent 带 payload，立即响铃")
                ringStart(this, newPayload)
            }
        }

        val action = intent.getStringExtra(EXTRA_ACTION)
        try {
            if (action != null) {
                NativeLog.log("MainActivity", "onNewIntent action=$action")
                channel?.invokeMethod("nativeActionPending", null)
            } else {
                channel?.invokeMethod("ringingPayload", null)
            }
        } catch (_: Exception) {}
    }

    private fun capturePayload(intent: Intent?) {
        val p = intent?.getStringExtra(EXTRA_PAYLOAD)
        if (!p.isNullOrEmpty()) {
            pendingPayload = p
        }
    }
}
