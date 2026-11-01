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
    /**
     * 渠道用响铃服务那一份（V1.14.0）。
     *
     * 之前复用 flutter_local_notifications 建的 med_alarm_v2：
     * Android 8+ 的渠道声音/震动创建后不可改，`setSound()` 静默无效，
     * 于是「通知来了但没声音」或「只有一声提示音」。自建渠道才拿得准。
     */
    private val CHANNEL_ID: String get() = RingingService.CHANNEL_ID

    /**
     * 保存 Dart 传来的排程表（JSON 数组字符串）并立即全部重排。
     *
     * V1.17.1：顺序必须是「按旧表取消 → 写新表 → 重排」。
     * 上一版先写新表再排，旧 id 就此失联：用户改了服药时间或删了药，
     * 旧时间那条闹钟还留在系统里，到点照样把界面顶起来 —— 而新表里
     * 已经没有它，谁也取消不掉。
     */
    @JvmStatic
    fun setSchedule(context: Context, json: String) {
        cancelAll(context)
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY, json).apply()
        } catch (_: Exception) {}
        scheduleAll(context)
        // 每次重排都顺手续一次看门狗，保证它一直链着（V1.17.5）
        scheduleWatchdog(context)
    }

    /**
     * 取消我们排的全部 alarm。
     *
     * V1.17.1 关键修复：V1.17.0 把闹钟的 operation 从广播改成了界面，
     * 但这里只按广播那条去 cancel —— 类型不同的 PendingIntent 匹配不上，
     * **界面那条根本取消不掉**。结果是改时间/删药后，旧闹钟继续在旧
     * 时间拉起界面响铃，最长残留 7 天。
     *
     * 现在三种都取消：广播那条（setExactAndAllowWhileIdle 的 operation）、
     * 界面那条（setAlarmClock 的 operation）、以及锁屏显示的 showIntent。
     */
    @JvmStatic
    fun cancelAll(context: Context) {
        try {
            val arr = read(context)
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            for (i in 0 until arr.length()) {
                val id = arr.getJSONObject(i).optInt("id", 0)
                if (id == 0) continue
                try { am.cancel(buildPending(context, id, "", "", "", "", 0)) } catch (_: Exception) {}
                try { am.cancel(buildActivityPending(context, id, "")) } catch (_: Exception) {}
                try { am.cancel(buildShowIntent(context, id)) } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    /**
     * 逐条排 alarm，返回成功排上的条数。
     *
     * 用 setAlarmClock 而不是 setExact：前者在锁屏上显示闹钟图标、
     * 不被 Doze 延后，是系统里优先级最高的定时方式。
     * 时间已过的直接跳过（避免立刻弹一堆过期提醒）。
     *
     * V1.17.4：改成返回条数 —— 开机/更新后的恢复需要知道到底补回了
     * 几条，日志里「重排 0 条」和「重排 21 条」意义完全不同。
     */
    @JvmStatic
    fun scheduleAll(context: Context): Int {
        var placed = 0
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
                val broadcastPi = buildPending(context, id, title, body, payload, name, at)
                val activityPi = buildActivityPending(context, id, payload)
                val showIntent = buildShowIntent(context, id)
                try {
                    // 主：闹钟到点直接拉起界面（绕过速冻）
                    am.setAlarmClock(AlarmManager.AlarmClockInfo(at, showIntent), activityPi)
                    placed++
                    // 备：晚 2 秒的广播（界面被拦时至少发通知 + 起响铃服务）
                    try {
                        am.setExactAndAllowWhileIdle(
                            AlarmManager.RTC_WAKEUP,
                            at + 2_000L,
                            broadcastPi,
                        )
                    } catch (_: Exception) {}
                } catch (_: Exception) {
                    // 没有精确闹钟权限时退到不精确，至少还有机会响
                    try {
                        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, broadcastPi)
                        placed++
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
        return placed
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
            val broadcastPi = buildPending(context, id, title, body, payload, name, at)
            val activityPi = buildActivityPending(context, id, payload)
            val showIntent = buildShowIntent(context, id)
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, showIntent), activityPi)
            // 备用广播：界面起不来时仍要发通知并响铃
            runCatching {
                am.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    at + 2_000L,
                    broadcastPi,
                )
            }
            NativeLog.log("GuardAlarm", "一次性闹钟已排（界面+广播双路） at=$at")
        } catch (e: Exception) {
            NativeLog.log("GuardAlarm", "setAlarmClock 失败: ${e.message}")
        }
    }

    /**
     * 闹钟的主 PendingIntent：**直接拉起界面**（V1.17.0 关键改动）
     *
     * ═══════════════════════════════════════════════════════════════
     * 为什么不能再用广播（用户第 10 次反馈：「切回软件界面才响」）
     * ═══════════════════════════════════════════════════════════════
     *
     * 现象是决定性的：到点不响，**一切回 App 就立刻响**。
     * 这不是延迟，是 vivo 的「应用速冻」把进程冻住了 —— 冻结状态下
     * 系统投递的广播只会排队，直到进程解冻才派发。日志里到点那一刻
     * 原生日志一片空白，正是广播还没被处理。
     *
     * 前台服务挡不住速冻（日志里守护服务明明在跑）。能绕过去的只有一条：
     * 让闹钟的 operation 本身是 **Activity**，而不是 BroadcastReceiver。
     * 系统在闹钟触发时会直接 startActivity（App 有悬浮窗权限，
     * 后台启动界面被允许），进程被一起拉活，界面和铃声同时到位。
     *
     * 备用那条广播仍然保留（见 scheduleAll），负责在界面被系统拦掉时
     * 至少发出通知并起响铃服务。
     */
    private fun buildActivityPending(
        context: Context,
        id: Int,
        payload: String,
    ): PendingIntent {
        val i = Intent(context, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
            putExtra(MainActivity.EXTRA_PAYLOAD, payload)
        }
        return PendingIntent.getActivity(
            context,
            id or 0x20000000,
            i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * 看门狗闹钟（V1.17.5）
     *
     * ═══════════════════════════════════════════════════════════════
     * 为什么必须要有它（用户第 11 份日志 + 观察）
     * ═══════════════════════════════════════════════════════════════
     *
     * 用户的原话很有决定性：
     *   「通知栏里有『正在守护用药提醒』的图标时到点会响，
     *     没有这个图标时就不会响。」
     *
     * 那个图标就是 ReminderGuardService 的前台通知。图标在 = 进程活着、
     * 有前台身份 = 系统不冻结它 = 闹钟广播能被及时处理。
     * 图标不在 = 服务已被 ROM 清掉 = 进程成了普通后台 = 被冻结，
     * 到点投递的广播只能排队，用户什么都感觉不到。
     *
     * 问题是 START_STICKY 救不回来：Android 12+ 禁止应用从后台启动
     * 前台服务，系统想重建也被拒。于是服务一死就是永久死，
     * 直到用户下次手动打开 App。
     *
     * 唯一能让「死掉的进程自己活过来」的，是系统级的定时唤醒 ——
     * 也就是闹钟本身。这条看门狗每 15 分钟醒一次：
     *   1. 先把下一次看门狗排上（链式自续，永不中断）；
     *   2. 补排提醒闹钟；
     *   3. 守护服务不在跑就把它拉起来。
     *
     * 精确闹钟触发的广播属于「允许启动前台服务」的豁免场景
     *（应用持 SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM），所以这一步
     * 在 Android 12+ 上合法。
     */
    // internal 而不是 private：同文件的 GuardAlarmReceiver 要拿它做判断
    internal const val WATCHDOG_ACTION = "com.medreminder.med_reminder.WATCHDOG"
    private const val WATCHDOG_REQ = 0x7000
    private const val WATCHDOG_INTERVAL_MS = 15 * 60 * 1000L

    /** 排下一次看门狗（幂等：同一个 PendingIntent 只会替换） */
    @JvmStatic
    fun scheduleWatchdog(context: Context) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = System.currentTimeMillis() + WATCHDOG_INTERVAL_MS
            val i = Intent(context, GuardAlarmReceiver::class.java).apply {
                action = WATCHDOG_ACTION
            }
            val pi = PendingIntent.getBroadcast(
                context,
                WATCHDOG_REQ,
                i,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } catch (_: Exception) {
                // 没有精确闹钟权限时退到不精确，仍然能起到「定期自愈」的作用
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (_: Exception) {}
    }

    /**
     * 锁屏上那个闹钟图标点开时用的 Intent。
     *
     * 和主 operation 用同一个 requestCode 会互相覆盖，所以单独抽出来，
     * 三处（排程 / 测试 / 取消）都用它，保证 cancel 时能精确匹配。
     */
    private fun buildShowIntent(context: Context, id: Int): PendingIntent {
        val i = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            context,
            id,
            i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
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
                // V1.17.1：界面已经在前台时不要再要全屏意图。
                // V1.16.0 只改了 RingingService 那份通知，这里一直写死 true，
                // 于是主路径（界面已被闹钟拉起）之后 2 秒广播又发一次通知，
                // 全屏意图把同一个 Intent 再投一次 → 响铃页叠层、返回要按两次。
                .setFullScreenIntent(pi, !MainActivity.isVisible)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setWhen(System.currentTimeMillis())
            // 注意：Android 8+ 上 setSound/setVibrate 对已存在的渠道无效，
            // 声音由渠道（RingingService.ensureChannel）决定，这里只是
            // 给低版本系统兜底。
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O && alarmUri != null) {
                b.setSound(alarmUri, attrs)
                b.setVibrate(longArrayOf(0, 800, 400, 800, 400, 800))
            }

            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            nm.notify(id, b.build())
        } catch (_: Exception) {}
    }

    private fun ensureChannel(context: Context) {
        RingingService.ensureChannel(context)
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

        // ═══════════════════════════════════════════════════════════
        // 开机 / 应用更新 → 把第二通道的闹钟补回来（V1.17.4）
        // ═══════════════════════════════════════════════════════════
        //
        // 系统在**重启**和**应用被更新**这两种情况下，会清空本应用通过
        // AlarmManager 排的全部闹钟。fln 那批有它自己的 boot receiver
        // （ScheduledNotificationBootReceiver）负责重排，所以通知还会来；
        // 但真正负责「弹界面 + 循环响铃」的第二通道如果没人接这一棒，
        // 就会一路空着，直到用户下次手动打开 App。
        //
        // 用户看到的现象正是如此：到点只有一条通知躺在通知栏，
        // 没有铃声、没有界面，点开才响 —— 而且只发生在「手机重启过」
        // 或「刚装了新版本」之后，所以感觉是「偶尔不响」。
        //
        // 对照 10-31 的日志：08:32 之前原生日志里一条「闹钟触发」都没有，
        // 直到 08:32:07 用户手动冷启动、重新排程（第二通道 21 条）为止。
        if (isRestoreAction(intent.action)) {
            val n = GuardAlarm.scheduleAll(context)
            // 重启/更新后看门狗也一起归零了，必须重新排上（V1.17.5）
            GuardAlarm.scheduleWatchdog(context)
            NativeLog.log(
                "GuardAlarmReceiver",
                "系统事件 ${intent.action} → 补排第二通道 $n 条",
            )
            NativeLog.flush(context)
            return
        }

        // ═══════════════════════════════════════════════════════════
        // 看门狗：每 15 分钟醒一次，负责「让死掉的自己活过来」（V1.17.5）
        // ═══════════════════════════════════════════════════════════
        //
        // 这条是整个后台方案里唯一的「自愈」入口。守护服务被 ROM 清掉后，
        // START_STICKY 在 Android 12+ 上救不回来（禁止后台启动前台服务），
        // 只能靠系统级的定时唤醒把它重新拉起来。
        //
        // 三步：续下一次 → 补排闹钟 → 拉起服务。顺序不能反 ——
        // 先续上链条，即使后面两步抛异常，15 分钟后还有机会。
        if (intent.action == GuardAlarm.WATCHDOG_ACTION) {
            GuardAlarm.scheduleWatchdog(context)
            val n = try { GuardAlarm.scheduleAll(context) } catch (_: Exception) { 0 }
            val wasRunning = ReminderGuardService.running
            if (!wasRunning) {
                try {
                    val si = Intent(context, ReminderGuardService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(si)
                    } else {
                        context.startService(si)
                    }
                } catch (e: Exception) {
                    NativeLog.log(
                        "GuardAlarmReceiver",
                        "看门狗拉起守护服务被拒: ${e.javaClass.simpleName} ${e.message}",
                    )
                }
            }
            NativeLog.log(
                "GuardAlarmReceiver",
                "看门狗：补排 $n 条，守护服务${if (wasRunning) "在跑" else "已尝试拉起"}",
            )
            NativeLog.flush(context)
            return
        }

        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title") ?: "该吃药了"
        val body = intent.getStringExtra("body") ?: ""
        val payload = intent.getStringExtra("payload") ?: ""

        // 到点这一刻的现场，全部记进 native_ring.log。
        // 上一轮排查最痛的地方就是这里没有任何痕迹。
        NativeLog.log(
            "GuardAlarmReceiver",
            "闹钟触发 id=$id overlay=${MainActivity.canDrawOverlays(context)} " +
                "fullScreen=${MainActivity.canUseFullScreenIntent(context)} " +
                "payload=${payload.take(40)}",
        )
        NativeLog.flush(context)

        if (payload.isEmpty()) {
            GuardAlarm.notifyReminder(context, id, title, body, payload)
            return
        }

        // ═══════════════════════════════════════════════════════════
        // 测试提醒：不要在通知栏留东西（V1.17.2，用户明确要求）
        // ═══════════════════════════════════════════════════════════
        //
        // 测试的目的是确认「到点会不会自己弹出来、会不会响」，
        // 通知栏里多一条「测试提醒」没有任何用处，反而会被反复点开
        // （点一次就重新响一次）。所以：
        // - 界面已经拉起并且在响同一条 → 直接收工，不发通知也不起服务；
        // - 界面没起来（锁屏/ROM 拦了）→ 仍然走兜底，否则用户会
        //   以为测试失败，而其实只是没弹出来。
        val isTest = payload.contains("\"test\":\"1\"") ||
            payload.contains("\"test\": \"1\"")
        if (isTest) {
            val alreadyRinging = MainActivity.isVisible &&
                MainActivity.ringingPayload == payload
            if (alreadyRinging) {
                NativeLog.log(
                    "GuardAlarmReceiver",
                    "测试提醒：界面已在响，跳过通知与响铃服务",
                )
                return
            }
            NativeLog.log(
                "GuardAlarmReceiver",
                "测试提醒：界面没起来，走兜底（通知 + 响铃服务）",
            )
            RingingService.start(context, id, title, body, payload)
            return
        }

        // 1) 通知栏保底（服务起不来时用户至少能看到）
        GuardAlarm.notifyReminder(context, id, title, body, payload)

        // 2) 前台服务：真正「响到用户处理为止」的那一层
        //
        // 为什么不是直接 startActivity：
        // Android 10+ 禁止后台启动界面，只有持悬浮窗才豁免；用户重装后
        // 这个权限会丢，而旧代码把异常吞了 —— 于是界面从未出现，
        // 日志里到点那一刻也是空的。
        // 前台服务有两件事做得到：进程不被立刻回收（铃声能持续），
        // 以及可以反复尝试拉起界面。
        RingingService.start(context, id, title, body, payload)
    }

    /** 这些系统事件发生后，本应用的闹钟会被系统清空，需要补排 */
    private fun isRestoreAction(action: String?): Boolean {
        return action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
    }
}
