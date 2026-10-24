package com.medreminder.med_reminder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
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

    /**
     * 每分钟轻量 ping 一次。
     *
     * 不是为了做业务，而是让进程持续有调度活动 —— 某些 ROM 把
     * 「长时间无调度」的后台进程判定为空闲并回收，这个心跳能绕开
     * 那类启发式判断。
     */
    private val heartbeat = object : Runnable {
        override fun run() {
            handler.postDelayed(this, 60_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        running = true
        handler.postDelayed(heartbeat, 60_000L)
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
