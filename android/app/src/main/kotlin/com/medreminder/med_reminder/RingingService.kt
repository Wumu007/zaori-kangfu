package com.medreminder.med_reminder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/**
 * 到点响铃前台服务（V1.14.0）
 *
 * ═══════════════════════════════════════════════════════════════════
 * 它解决的是什么（用户第 7 份日志）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 日志证据：
 *   21:32:20  排程汇总 | 成功 96 条 / 失败 0 条     ← 排期没问题
 *   21:32:20  权限快照 | 通知=true 精确闹钟=true 电池白名单=true
 *   07:51:12  点开原生通知 | 热启动进响铃页         ← 用户「点」了才响
 *
 * 关键点：**到点那一刻日志里一条记录都没有**。
 * 如果响铃页曾被拉起，Dart 一定会写「点开原生通知」或「冷启动来自原生通知」。
 * 一条都没有 = 界面从未被拉起。原因是两个：
 *
 * 1. `startActivity()` 从后台（BroadcastReceiver）发起，Android 10+ 默认
 *    直接丢弃。只有持有悬浮窗权限才豁免 —— 用户重装后这个权限没了，
 *    而我们当时把异常吞了，所以完全静默。
 * 2. 铃声靠 `MainActivity.ringStart()` 的静态播放器。进程被 ROM 冻结时，
 *    onReceive 结束后进程立刻回收，铃声刚起就被掐断 —— 等于没响。
 *
 * 前台服务同时解决这两件事：
 * - 前台服务让进程「有身份」，onReceive 结束后不会被立刻回收，铃声能一直响；
 * - 服务里可以安全地持有 WakeLock 唤醒屏幕，并反复尝试拉起界面。
 *
 * 另外，通知渠道换成**我们自己新建的** med_ring_v3：
 * Android 8+ 渠道的声音/震动创建后不可修改，此前复用 fln 的渠道，
 * `setSound()` 根本不生效（渠道里是什么就是什么）。自建渠道才拿得准。
 */
class RingingService : Service() {

    companion object {
        const val CHANNEL_ID = "med_ring_v3"
        const val NOTIFICATION_ID = 9101

        const val EXTRA_ID = "ring_id"
        const val EXTRA_TITLE = "ring_title"
        const val EXTRA_BODY = "ring_body"
        const val EXTRA_PAYLOAD = "ring_payload"

        /** 服务是否正在运行（Dart 侧查询「现在是不是在响」） */
        @Volatile
        var active: Boolean = false
            private set

        /** 已开始响铃的 payload，用于去重（同一条重复触发只响应一次） */
        @Volatile
        private var ringingPayload: String? = null

        /**
         * 启动响铃。只能从「能合法启动前台服务」的场景调用：
         * 精确闹钟广播、用户点通知、App 自身在前台。
         */
        @JvmStatic
        fun start(context: Context, id: Int, title: String, body: String, payload: String) {
            // 同一条提醒已经在响 —— 不重复叠加（日志里出现过一次点开触发 4 次）
            if (active && ringingPayload == payload) {
                NativeLog.log("RingingService", "已在响铃，跳过重复启动 payload=${payload.take(40)}")
                return
            }
            ringingPayload = payload
            val i = Intent(context, RingingService::class.java).apply {
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
                putExtra(EXTRA_PAYLOAD, payload)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(i)
                } else {
                    context.startService(i)
                }
                NativeLog.log("RingingService", "startForegroundService 已下发")
            } catch (e: Exception) {
                // Android 12+ 后台启动 FGS 受限。精确闹钟本属豁免场景，
                // 但国产 ROM 仍可能拒绝 —— 记下来，下次日志能直接看到。
                NativeLog.log("RingingService", "启动前台服务被拒: ${e.javaClass.simpleName} ${e.message}")
            }
        }

        /** 建渠道。GuardAlarm 也用它，保证全 App 只有一份闹钟渠道配置 */
        @JvmStatic
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    "服药闹钟（响铃）",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "到点像闹钟一样持续响铃，直到你处理"
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 800)
                    enableLights(true)
                    setShowBadge(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                    if (alarmUri != null) {
                        val attrs = AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                        setSound(alarmUri, attrs)
                    }
                    try {
                        setBypassDnd(true)
                    } catch (_: Exception) {}
                }
                nm.createNotificationChannel(ch)
            } catch (_: Exception) {}
        }

        @JvmStatic
        fun stop(context: Context, reason: String) {
            NativeLog.log("RingingService", "停止响铃: $reason")
            ringingPayload = null
            try {
                context.stopService(Intent(context, RingingService::class.java))
            } catch (_: Exception) {}
            MainActivity.ringStop()
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var launchAttempt = 0

    /**
     * 拉起界面。
     *
     * V1.15.0：从「每 2.5 秒重试 3 次」改成「只补一次」。
     *
     * 用户日志里一次提醒出现了 3 条「点开原生通知」—— 就是这三次重试
     * 每次都会触发一次 onNewIntent，把响铃页反复推到栈上（返回要按三次）。
     * 实际日志证明首次 startActivity 就是成功的（`startActivity 成功
     * overlay=true`），重试纯属多余；只有界面确实不在前台时才补一次。
     */
    private val launchTask = object : Runnable {
        override fun run() {
            if (!active) return
            if (launchAttempt >= 2) return
            if (launchAttempt == 1 && MainActivity.isVisible) return
            launchAttempt++
            MainActivity.launchRinging(this@RingingService, currentPayload)
            handler.postDelayed(this, 2000L)
        }
    }

    private var currentPayload: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val payload = intent?.getStringExtra(EXTRA_PAYLOAD) ?: currentPayload
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "该吃药了"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "到服药时间了，点开处理"
        val id = intent?.getIntExtra(EXTRA_ID, 0) ?: 0
        currentPayload = payload

        NativeLog.log(
            "RingingService",
            "onStartCommand title=$title payload=${payload.take(40)} " +
                "canDrawOverlays=${MainActivity.canDrawOverlays(this)} " +
                "fullScreenAllowed=${canUseFullScreenIntent(this)}",
        )

        try {
            startForegroundCompat(buildNotification(id, title, body, payload))
            active = true
        } catch (e: Exception) {
            NativeLog.log("RingingService", "startForeground 失败: ${e.message}")
            active = false
            stopSelf()
            return START_NOT_STICKY
        }

        acquireWakeLock()

        // 1) 先响起来（不依赖界面上不上得来）
        try {
            MainActivity.ringStart(this)
            NativeLog.log("RingingService", "循环铃声已启动")
        } catch (e: Exception) {
            NativeLog.log("RingingService", "铃声启动失败: ${e.message}")
        }

        // 2) 再反复尝试把界面拉到最前
        launchAttempt = 0
        handler.removeCallbacks(launchTask)
        handler.post(launchTask)

        return START_STICKY
    }

    override fun onDestroy() {
        active = false
        handler.removeCallbacksAndMessages(null)
        releaseWakeLock()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ 唤醒

    /**
     * 持 WakeLock 直到用户处理。
     *
     * 用 PARTIAL_WAKE_LOCK：保证 CPU 不休眠，铃声与震动才能持续。
     * 屏幕点亮交给 Activity 的 turnScreenOn / 通知的全屏意图；
     * 这边额外试一次「点亮屏幕」，覆盖锁屏且界面拉起失败的情况。
     */
    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (wakeLock?.isHeld == true) return
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "med_reminder:ringing",
            ).apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L) // 最多 10 分钟，避免异常时永久占电
            }
            NativeLog.log("RingingService", "WakeLock 已获取")
        } catch (e: Exception) {
            NativeLog.log("RingingService", "WakeLock 失败: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
    }

    // ------------------------------------------------------------------ 通知

    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                n,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun buildNotification(
        id: Int,
        title: String,
        body: String,
        payload: String,
    ): Notification {
        ensureChannel(this)

        // 点通知 → 打开 App 的响铃页
        val open = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
            putExtra(MainActivity.EXTRA_PAYLOAD, payload)
        }
        val openPi = PendingIntent.getActivity(
            this,
            9200 + (id and 0xFF),
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_ALARM)
            .setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)          // 响铃期间不可划掉：必须点按钮才停
            .setAutoCancel(false)
            .setShowWhen(true)
            .setWhen(System.currentTimeMillis())
            .setContentIntent(openPi)
            // 锁屏/息屏时由系统直接把界面顶上来（Android 14+ 需要用户授权
            // 「全屏通知」，设置页有入口；无授权时至少是横幅 + 铃声）
            .setFullScreenIntent(openPi, true)

        builder.addAction(action("已服药", "taken", payload, 9201))
        builder.addAction(action("延后 10 分钟", "snooze", payload, 9202))
        builder.addAction(action("跳过本次", "skip", payload, 9203))

        return builder.build()
    }

    private fun action(label: String, action: String, payload: String, req: Int): Notification.Action {
        val i = Intent(this, RingingActionReceiver::class.java).apply {
            putExtra("action", action)
            putExtra("payload", payload)
        }
        val pi = PendingIntent.getBroadcast(
            this,
            req,
            i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Action.Builder(
            android.R.drawable.ic_menu_send,
            label,
            pi,
        ).build()
    }

    /** Android 14+ 的全屏通知授权状态（false 时锁屏不会自动弹界面） */
    private fun canUseFullScreenIntent(context: Context): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                nm.canUseFullScreenIntent()
            } else {
                true
            }
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * 通知上三个按钮的处理。
 *
 * 铃声必须**立刻**停 —— 用户已经做出决定了，多响一秒都是打扰。
 * 真正落库交给 Dart：把 action 存起来并拉起 App，
 * Dart 冷启动/热启动时读走并写入记录。
 */
class RingingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra("action") ?: return
        val payload = intent.getStringExtra("payload") ?: ""

        NativeLog.log("RingAction", "用户点了 $action")

        // 1) 先停铃（无论后面成不成，都不能继续响）
        RingingService.stop(context, "用户点了 $action")

        // 2) 记下待处理动作，交给 Dart 落库
        NativeLog.savePendingAction(context, action, payload)

        // 3) 拉起 App 让 Dart 立刻处理。
        //    用户主动点通知按钮属于「用户交互」，启动界面是允许的。
        try {
            MainActivity.launchWithAction(context, payload, action)
        } catch (_: Exception) {}
    }
}

/**
 * 原生侧日志。
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么需要它（这轮排查的直接教训）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 用户日志里「到点那一刻」什么都没有 —— 因为广播、前台服务、startActivity
 * 全在原生层，而原来的 AppLog 只记 Dart 事件。出事时我们只能猜。
 *
 * 这里把原生关键路径写进应用私有目录的 native_ring.log，
 * Dart 导出日志时把它拼在末尾。下次再出问题，一眼能看出：
 * - 广播有没有进（没进 = 系统没触发闹钟）
 * - 前台服务有没有起来（被拒 = ROM 限制）
 * - 悬浮窗 / 全屏通知有没有授权
 * - startActivity 抛了什么
 */
object NativeLog {
    private const val FILE = "native_ring.log"
    private const val MAX_LINES = 400
    private const val PREFS = "native_pending_action"
    private const val KEY_ACTION = "action"
    private const val KEY_PAYLOAD = "payload"

    @JvmStatic
    fun log(tag: String, msg: String) {
        try {
            val line = "${stamp()} [$tag] $msg"
            android.util.Log.i("MedReminder", line)
            pending.add(line)
            if (pending.size > 60) pending.removeAt(0)
        } catch (_: Exception) {}
    }

    private val pending = mutableListOf<String>()

    /** 追加到文件（在主线程调用也很快，只是一行文本） */
    @JvmStatic
    fun flush(context: Context) {
        if (pending.isEmpty()) return
        try {
            val f = java.io.File(context.filesDir, FILE)
            val lines = pending.toList()
            pending.clear()
            val all = (if (f.exists()) f.readLines() else emptyList()) + lines
            val tail = if (all.size > MAX_LINES) all.subList(all.size - MAX_LINES, all.size) else all
            f.writeText(tail.joinToString("\n"))
        } catch (_: Exception) {}
    }

    @JvmStatic
    fun read(context: Context): String {
        val out = StringBuilder()
        try {
            val f = java.io.File(context.filesDir, FILE)
            if (f.exists()) out.append(f.readText())
        } catch (_: Exception) {}
        if (pending.isNotEmpty()) {
            if (out.isNotEmpty()) out.append('\n')
            out.append(pending.joinToString("\n"))
        }
        return out.toString()
    }

    @JvmStatic
    fun savePendingAction(context: Context, action: String, payload: String) {
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_ACTION, action)
                .putString(KEY_PAYLOAD, payload)
                .apply()
        } catch (_: Exception) {}
    }

    /** 取走待处理动作（Dart 处理完后清空） */
    @JvmStatic
    fun takePendingAction(context: Context): String? {
        return try {
            val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val a = sp.getString(KEY_ACTION, null)
            if (a != null) sp.edit().clear().apply()
            val p = sp.getString(KEY_PAYLOAD, "") ?: ""
            if (a == null) null else "$a\u0001$p"
        } catch (_: Exception) {
            null
        }
    }

    private fun stamp(): String {
        val d = java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)
        return d.format(java.util.Date())
    }
}
