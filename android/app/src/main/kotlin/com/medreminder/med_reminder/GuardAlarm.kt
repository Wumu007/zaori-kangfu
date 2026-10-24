package com.medreminder.med_reminder

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * 提醒的第二条通道（V1.7.0）
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么需要一条「重复」的通道
 * ═══════════════════════════════════════════════════════════════════
 *
 * 用户日志证明：精确闹钟=true、电池白名单=true、守护服务已启动、
 * 排程成功 29 条失败 0 条 —— App 内部一切正常，但切后台/锁屏后到点
 * 仍然没有通知。也就是说：flutter_local_notifications 通过它自己的
 * BroadcastReceiver 排的那批 alarm，被系统（vivo 的冻结/清理）拦掉了。
 *
 * 软件层无法命令系统不拦，能做的只有**再摆一条独立的通道**：
 * - 用自己的 AlarmManager.setAlarmClock 排一批（和插件那批并行）；
 * - 用自己的 BroadcastReceiver 接收（静态注册，进程死了也会被拉起）；
 * - 用自己的 NotificationManager 发通知。
 *
 * 两条通道用**同一个通知 id**（Dart 侧算好传过来），所以即便两条
 * 都成功触发，通知栏里也只会有一条，不会重复打扰。
 *
 * 排程表由 Dart 在每次启动/回前台时通过 setGuardSchedule 交过来，
 * 存在 SharedPreferences 里 —— 进程被杀后 service 重建或开机后
 * （配合 MY_PACKAGE_REPLACED / BOOT 广播）仍能恢复。
 */
object GuardAlarm {

    private const val PREFS = "guard_alarm_v1"
    private const val KEY = "items"
    private const val CHANNEL_ID = "med_alarm_v2"

    /** 保存 Dart 传来的排程表（JSON 数组字符串）并立即全部重排 */
    @JvmStatic
    fun setSchedule(context: Context, json: String) {
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY, json).apply()
        } catch (_: Exception) {}
        scheduleAll(context)
    }

    /** 取消我们排的全部 alarm */
    @JvmStatic
    fun cancelAll(context: Context) {
        try {
            val arr = read(context)
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            for (i in 0 until arr.length()) {
                val id = arr.getJSONObject(i).optInt("id", 0)
                val pi = buildPending(context, id, "", "", "", "", 0)
                am.cancel(pi)
            }
        } catch (_: Exception) {}
    }

    /**
     * 逐条排 alarm。
     *
     * 用 setAlarmClock 而不是 setExact：前者在锁屏上显示闹钟图标、
     * 不被 Doze 延后，是系统里优先级最高的定时方式。
     * 时间已过的直接跳过（避免立刻弹一堆过期提醒）。
     */
    @JvmStatic
    fun scheduleAll(context: Context) {
        try {
            val arr = read(context)
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val now = System.currentTimeMillis()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val id = o.optInt("id", 0)
                val at = o.optLong("at", 0L)
                if (id == 0 || at <= now + 1000L) continue

                val title = o.optString("title", "该吃药了")
                val body = o.optString("body", "")
                val payload = o.optString("payload", "")
                val name = o.optString("name", "")
                val pi = buildPending(context, id, title, body, payload, name, at)

                val showIntent = PendingIntent.getActivity(
                    context,
                    id,
                    Intent(context, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                try {
                    am.setAlarmClock(
                        AlarmManager.AlarmClockInfo(at, showIntent),
                        pi,
                    )
                } catch (_: Exception) {
                    // 没有精确闹钟权限时退到不精确，至少还有机会响
                    try {
                        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
    }

    /**
     * 排一条单独的闹钟（设置页「测试提醒」用）
     *
     * 测试也走第二通道，这样用户测的就是真实的后台链路：
     * 原生 alarm → 原生 receiver → 发通知 + （有权限时）直接弹响铃页。
     */
    @JvmStatic
    fun setOneShot(
        context: Context,
        id: Int,
        at: Long,
        title: String,
        body: String,
        payload: String,
        name: String,
    ) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = buildPending(context, id, title, body, payload, name, at)
            val showIntent = PendingIntent.getActivity(
                context,
                id,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, showIntent), pi)
        } catch (_: Exception) {
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val pi = buildPending(context, id, title, body, payload, name, at)
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } catch (_: Exception) {}
        }
    }

    private fun buildPending(
        context: Context,
        id: Int,
        title: String,
        body: String,
        payload: String,
        name: String,
        at: Long,
    ): PendingIntent {
        val i = Intent(context, GuardAlarmReceiver::class.java).apply {
            putExtra("id", id)
            putExtra("title", title)
            putExtra("body", body)
            putExtra("payload", payload)
            putExtra("name", name)
            putExtra("at", at)
        }
        return PendingIntent.getBroadcast(
            context,
            id,
            i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun read(context: Context): JSONArray {
        return try {
            val s = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY, "[]") ?: "[]"
            JSONArray(s)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    /**
     * 发通知（原生自建，不经过 flutter_local_notifications）
     *
     * 渠道复用 fln 建的 med_alarm_v2（最高重要性、闹钟音量、震动）；
     * 如果它不存在（例如刚装完还没启动过 App），这里按同样配置补建。
     */
    @JvmStatic
    fun notifyReminder(
        context: Context,
        id: Int,
        title: String,
        body: String,
        payload: String,
    ) {
        try {
            ensureChannel(context)

            // 点通知/全屏弹出 → MainActivity，payload 通过 extra 带过去，
            // Dart 侧 takePendingPayload() 取到后直接进响铃页
            val open = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_NEW_TASK,
                )
                putExtra(MainActivity.EXTRA_PAYLOAD, payload)
            }
            val pi = PendingIntent.getActivity(
                context,
                id,
                open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val alarmUri: Uri? =
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            b.setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setCategory(Notification.CATEGORY_ALARM)
                .setPriority(Notification.PRIORITY_MAX)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setFullScreenIntent(pi, true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setWhen(System.currentTimeMillis())
            if (alarmUri != null) {
                b.setSound(alarmUri, attrs)
            }
            b.setVibrate(longArrayOf(0, 800, 400, 800, 400, 800))

            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            nm.notify(id, b.build())
        } catch (_: Exception) {}
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            // 已存在时系统会忽略（渠道不可改），这正是我们要的：
            // 和 fln 用同一个 id，配置以先创建的那份为准
            val ch = NotificationChannel(
                CHANNEL_ID,
                "服药提醒（闹钟式）",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "到点像闹钟一样响铃、震动并全屏提醒服药"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 800)
                enableLights(true)
                val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                if (alarmUri != null) {
                    val attrs = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    setSound(alarmUri, attrs)
                }
            }
            nm.createNotificationChannel(ch)
        } catch (_: Exception) {}
    }
}

/**
 * 第二通道的接收器。
 *
 * 静态注册在 manifest 里 —— 即使 App 进程已经被 ROM 清掉，
 * 系统触发 alarm 时仍会实例化本 receiver 并调用 onReceive。
 */
class GuardAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title") ?: "该吃药了"
        val body = intent.getStringExtra("body") ?: ""
        val payload = intent.getStringExtra("payload") ?: ""

        // 1) 通知栏保底：即使后面弹界面失败，用户也能看到一条
        GuardAlarm.notifyReminder(context, id, title, body, payload)

        if (payload.isEmpty()) return

        // 2) V1.8.0：直接从后台拉起响铃界面并立即响铃
        //
        // 用户实测「切到别的应用后只在通知栏出现一条，点了才响」——
        // 因为通知的 fullScreenIntent 在 Android 14+ 对非闹钟类应用
        // 默认不授权，vivo 又更严。这里改成主动 startActivity：
        // 持有悬浮窗权限时系统明确允许后台启动 Activity，界面会
        // 直接盖在别的应用之上；没有权限时调用会被系统吞掉，
        // 至少还有第 1 步的通知兜底。
        try {
            MainActivity.launchRinging(context, payload)
        } catch (_: Exception) {}
        try {
            MainActivity.ringStart(context)
        } catch (_: Exception) {}
    }
}
