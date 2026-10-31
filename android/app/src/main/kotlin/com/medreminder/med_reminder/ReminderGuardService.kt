package com.medreminder.med_reminder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * 提醒守护前台服务
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么需要它（V1.5.0 实测：「只有 App 界面里能提醒」）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 通知排程本身是好的 —— 前台能看到通知就证明了这一点。问题在于
 * 一旦 App 离开前台，vivo/小米这类 ROM 的省电策略会对「普通后台进程」
 * 立刻降级甚至冻结：
 *
 * - 冻结后 App 排的 AlarmManager 闹钟会被系统一并取消或延后；
 * - 部分 ROM 还会把该 App 的通知权限在后台状态下临时降级。
 *
 * 前台服务（Foreground Service）是 Android 给「用户明确知道正在运行」
 * 的服务留的通道：它有常驻通知、优先级等同前台 App，系统不会轻易冻结。
 * 微信、支付宝、各类闹钟 App 都靠它保活。
 *
 * 注意诚实说明：这是**显著提高**后台可靠性，不是 100% 保证 ——
 * 国产 ROM 仍可能杀前台服务，所以还需要用户在系统里允许自启动 /
 * 后台高耗电，并加入电池优化白名单（设置页有对应入口）。
 *
 * 服务本身不负责发提醒（通知仍由 flutter_local_notifications 的
 * AlarmManager 触发），只负责「让进程活着，闹钟不被清掉」。
 */
class ReminderGuardService : Service() {

    companion object {
        const val CHANNEL_ID = "med_guard_v1"
        const val NOTIFICATION_ID = 9001

        /** App 是否已经请求过开启守护（进程内标记，供 Dart 查询） */
        @Volatile
        var running: Boolean = false
            private set
    }

    private val handler = Handler(Looper.getMainLooper())

    private var tick = 0

    /**
     * 每分钟一次心跳；每 5 分钟顺手把闹钟补排一遍（V1.17.4）。
     *
     * 开机 / 应用更新这两种「系统会清空全部闹钟」的情况，现在由
     * GuardAlarmReceiver 的 BOOT_COMPLETED / MY_PACKAGE_REPLACED
     * 接住了。但国产 ROM 还会在运行期间自己把第三方闹钟清掉
     *（省电策略、深度冻结解冻、后台清理），这类清空**没有任何广播**，
     * 只能靠「定期补一遍」兜底 —— 这正是「偶尔不响」的另一半。
     *
     * 补排是幂等的：同一个 PendingIntent 再 setAlarmClock 只会替换，
     * 不会重复响；已过点的那几条会被 scheduleAll 跳过，也不会补响旧提醒。
     * 每 5 分钟二十几条 AlarmManager 写入，耗电可忽略。
     */
    private val heartbeat = object : Runnable {
        override fun run() {
            tick++
            if (tick % 5 == 0) {
                try {
                    val n = GuardAlarm.scheduleAll(this@ReminderGuardService)
                    // 每半小时记一条，避免把原生日志刷满（上限 400 行）
                    if (tick % 30 == 0) {
                        NativeLog.log("GuardService", "例行补排 $n 条闹钟（已运行 $tick 分钟）")
                    }
                } catch (_: Exception) {}
            }
            handler.postDelayed(this, 60_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        // V1.8.0：显式声明前台服务类型。
        // Android 14 起若不传 type，部分 ROM 会直接抛
        // SecurityException/ForegroundServiceStartNotAllowedException，
        // 服务创建失败 —— 日志里「启动失败或被系统拒绝」就是它。
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
            running = true
            handler.postDelayed(heartbeat, 60_000L)
        } catch (e: Exception) {
            android.util.Log.e("MedReminder", "guard startForeground failed: $e")
            running = false
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY：被系统杀掉后系统会尝试重建服务
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(heartbeat)
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 常驻通知必须低调：低重要性、无声、不震动、不显示角标。
        // 它只是告诉用户「守护在跑」，不该打扰。
        val ch = NotificationChannel(
            CHANNEL_ID,
            "后台提醒守护",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "保持应用在后台也能准时提醒服药"
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("早日康复")
            .setContentText("正在守护用药提醒，切到后台也会准时响")
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentIntent(pi)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }
}
