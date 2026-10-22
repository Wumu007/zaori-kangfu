import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/backup_service.dart';
import '../services/native_bridge.dart';
import '../services/reminder_scheduler.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/ui_kit.dart';
import 'export_flow.dart';
import 'medication_list_page.dart';

/// 「我的」页（设置）
///
/// 只放三类东西：药品入口、影响提醒行为的设置、权限修复与说明。
/// 原则：每个开关都必须立刻生效，不做「设了但不生效」的假设置。
///
/// 【Bug 修复记录】「通知里延后多久」下方的选项框互相重叠。
/// 原因：选项容器用了 `Row` + 固定宽度分配，屏幕一窄（或开了大字号）总宽度
/// 超过可用宽度，最后一项被挤出边界压到前面的框上 —— 视觉重叠但点击仍然
/// 命中自己那一层，所以「不影响点击」很符合症状。
/// 修法：改用 [ChoiceChips]（内部是 `Wrap`），宽度自适应、放不下自动换行，
/// 并且给每个选项一个最小高度，既不会重叠也不会挤成一条细缝。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const List<int> _snoozeOptions = <int>[5, 10, 15, 30];

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[state, state.settings]),
      builder: (BuildContext context, _) {
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.pageX, 10, AppSpace.pageX, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  const Text(
                    '我的',
                    style: TextStyle(
                      fontSize: AppText.largeTitle,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                      letterSpacing: -0.5,
                      height: 1.15,
                    ),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${state.meds.length} 种药在提醒',
                      style: const TextStyle(
                        fontSize: AppText.caption,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.pageX,
                  0,
                  AppSpace.pageX,
                  28,
                ),
                children: <Widget>[
                  // ---- 分组 1：药品 ----
                  const SectionHeader('用药'),
                  AppCard(
                    shadow: true,
                    child: AppNavRow(
                      icon: AppIcons.medication,
                      tone: AppIconTone.blue,
                      title: '药品管理',
                      subtitle: '添加、编辑、删除药品；可停止提醒并保留历史',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MedicationListPage(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapLg),

                  // ---- 分组 2：提醒 ----
                  const SectionHeader('提醒'),
                  AppCard(
                    shadow: true,
                    child: AppNavRow(
                      icon: state.notificationGranted
                          ? AppIcons.notification
                          : AppIcons.reminderOff,
                      tone: state.notificationGranted
                          ? AppIconTone.green
                          : AppIconTone.orange,
                      title: '通知与闹钟权限',
                      subtitle: state.notificationGranted
                          ? '已允许，到点会响'
                          : '未允许，到点可能不响 —— 点这里去开',
                      onTap: () => _openPermissionSheet(context),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gap),
                  // V1.5.0：电池白名单 —— 「后台/锁屏收不到提醒」的主要解法。
                  // vivo/小米/OPPO 的省电策略会冻结后台应用并取消其闹钟，
                  // 通知权限全开也一样收不到。加入电池优化白名单是标准解法。
                  const _BatteryRow(),
                  const SizedBox(height: AppSpace.gap),
                  AppCard(
                    shadow: true,
                    child: Column(
                      children: <Widget>[
                        _ToneSwitchTile(
                          icon: AppIcons.text,
                          tone: AppIconTone.purple,
                          value: state.settings.largeText,
                          onChanged: state.settings.setLargeText,
                          title: '大字号',
                          subtitle: '整体放大 18%，看不清时再打开',
                        ),
                        const AppDivider(),
                        _ToneSwitchTile(
                          icon: AppIcons.shield,
                          tone: AppIconTone.green,
                          value: state.settings.confirmBeforeSkip,
                          onChanged: state.settings.setConfirmBeforeSkip,
                          title: '跳过本次前再确认',
                          subtitle: '防止误触把一顿药记成「已跳过」',
                        ),
                        const AppDivider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  const AppIconTile(
                                    AppIcons.snooze,
                                    tone: AppIconTone.orange,
                                    size: 30,
                                  ),
                                  const SizedBox(width: 11),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: const <Widget>[
                                      Text(
                                        '通知里「稍后提醒」多久',
                                        style: TextStyle(
                                          fontSize: AppText.bodySm,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.ink,
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        '点通知上的「稍后提醒」后，隔多久再响一次',
                                        style: TextStyle(
                                          fontSize: AppText.tiny,
                                          color: AppColors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // 关键修复：Wrap 布局，宽度自适应 + 自动换行
                              ChoiceChips<int>(
                                options: _snoozeOptions,
                                value: state.settings.snoozeMinutes,
                                onChanged: _onSnoozeChanged,
                                labelOf: (int m) => '$m 分钟',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapLg),

                  // ---- 分组 3：数据 ----
                  const SectionHeader('数据与说明'),
                  AppCard(
                    shadow: true,
                    child: Column(
                      children: <Widget>[
                        AppNavRow(
                          icon: AppIcons.backup,
                          tone: AppIconTone.purple,
                          title: '备份与恢复',
                          subtitle: '换手机时把药品和记录完整带走',
                          onTap: () => _openDataSheet(context),
                        ),
                        const AppDivider(),
                        AppNavRow(
                          icon: AppIcons.info,
                          tone: AppIconTone.gray,
                          title: '免责声明',
                          subtitle: '本 App 只做提醒与记录',
                          onTap: () => _showDisclaimer(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Center(
                    child: Text(
                      '早日康复 v1.5.0 · 本地版',
                      style: TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 延后时长改了要立刻重排通知，否则旧通知上的按钮还是老时长
  Future<void> _onSnoozeChanged(int minutes) async {
    final AppState state = AppState.instance;
    await state.settings.setSnoozeMinutes(minutes);
    await ReminderScheduler.instance.resync(state.meds);
  }

  /// 打开权限体检面板
  ///
  /// 【Bug 修复】上一版这里是「点一下 → 申请一次 → 弹一句提示」：
  /// 通知早就允许时申请立即返回成功，于是只弹「通知权限已开启」，
  /// 而真正导致提醒被推迟的**精确闹钟**没开这件事，用户永远看不到，
  /// 也点不进系统设置 —— 表现就是「这个选项不能选，只会说已开启」。
  ///
  /// 现在改成：先真实查询两项状态 → 在面板里分项列出「已开 / 没开」→
  /// 没开的给一个明确的按钮直接跳系统对应页面 → 回到 App 时自动复查。
  Future<void> _openPermissionSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (BuildContext ctx) => _PermissionSheet(
        onChanged: (bool granted) {
          AppState.instance.setNotificationGranted(granted);
        },
      ),
    );
    // 用户可能刚从系统设置回来，刷新一下首页的提示条
    if (!context.mounted) return;
    await _refreshPermissionState();
  }

  /// 静默复查（不弹提示），供返回时调用
  Future<void> _refreshPermissionState() async {
    final PermissionReport report =
        await ReminderScheduler.instance.checkPermissions();
    AppState.instance.setNotificationGranted(report.allGood);
  }

  void _showDisclaimer(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('免责声明'),
        content: const Text(
          '本 App 仅提供服药时间提醒与记录，不提供诊断、剂量建议或药物相互作用判断。\n\n'
          '请严格按医生处方和药品说明书服药。如出现漏服、误服或身体不适，请咨询医生或药师，'
          '不要仅依据本 App 的提示处理。',
          style: TextStyle(
            fontSize: AppText.caption,
            height: 1.75,
            color: AppColors.sub,
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('我知道了')),
        ],
      ),
    );
  }

  /// 备份与恢复面板
  ///
  /// 三件事：导出备份（换手机带走）、导入备份（新手机恢复）、以及
  /// 「数据存在哪」的说明。之所以把它们放一起，是因为用户问「我的数据呢」
  /// 和「怎么带走」其实是同一个问题。
  Future<void> _openDataSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (BuildContext ctx) => _DataSheet(
        onImported: () async {
          final AppState state = AppState.instance;
          await state.refresh();
          // 导入的药品也要真的会响 —— 只刷新界面不排通知等于没恢复
          await ReminderScheduler.instance.resync(state.meds);
        },
      ),
    );
  }
}

/// 权限设置面板
///
/// 设计取舍（用户反馈直接决定的）：
/// 「点一下只告诉我已开启」根本不算设置项 —— 用户要的是**能选**。
/// 所以这里改成两个真的开关：
/// - 开关的状态 = 系统里的真实状态（不是本地记的一个布尔值）；
/// - 打开开关 → 直接跳到系统对应的授权页；
/// - 关闭开关 → 也跳系统页（Android 不允许第三方 App 自己关掉权限），
///   并在跳转前说清楚「这里关掉，到点就不会响了」；
/// - 从系统页回来（resumed）自动重查，开关跟着系统状态走，不存在两边不一致。
///
/// 只放两项：通知、精确闹钟。麦克风不在这里 —— 它跟「到点响不响」无关，
/// 在第一次用语音录入时一次性申请，不打扰日常使用。
class _PermissionSheet extends StatefulWidget {
  const _PermissionSheet({required this.onChanged});

  /// 状态变化时回传给设置页，用于更新首页提示条
  final ValueChanged<bool> onChanged;

  @override
  State<_PermissionSheet> createState() => _PermissionSheetState();
}

class _PermissionSheetState extends State<_PermissionSheet>
    with WidgetsBindingObserver {
  PermissionReport? _report;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置切回来时自动复查 —— 用户不需要再点一次「刷新」
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final PermissionReport report =
        await ReminderScheduler.instance.checkPermissions();
    if (!mounted) return;
    setState(() => _report = report);
    widget.onChanged(report.allGood);
  }

  /// 用户拨动「通知」开关
  ///
  /// 两种情况都跳系统页：
  /// - 现在是关的 → 调一次系统授权弹窗（还能弹的话），弹不出来再跳设置页；
  /// - 现在是开的 → 引导去系统里关（App 无权自己关），并提示后果。
  Future<void> _toggleNotifications(bool want) async {
    if (!want) {
      final bool? go = await _confirmClose(
        title: '关掉通知？',
        body: '关掉之后，到点不会有任何提醒，服药清单也不会弹出来。\n'
            '建议先停药或改用别的提醒方式再关。',
      );
      if (go != true) return;
      if (!mounted) return;
      await openAppSettings();
      await _check();
      return;
    }

    setState(() => _busy = true);
    await ReminderScheduler.instance.requestPermissions();
    await _check();
    if (!mounted) return;
    setState(() => _busy = false);

    final PermissionReport? r = _report;
    if (r != null && !r.notifications) {
      // 用户以前选过「不再询问」，系统不会弹了，只能去设置页手动开
      await openAppSettings();
      await _check();
    }
  }

  /// 用户拨动「精确闹钟」开关
  Future<void> _toggleExactAlarms(bool want) async {
    if (!want) {
      final bool? go = await _confirmClose(
        title: '关掉精确闹钟？',
        body: '关掉之后提醒仍然会响，但系统可能把它推迟几分钟到几十分钟，'
            '也可能在息屏后合并成一条。',
      );
      if (go != true) return;
      if (!mounted) return;
    }
    setState(() => _busy = true);
    await ReminderScheduler.instance.openExactAlarmSettings();
    // 部分 ROM 不会暂停 App，稍等一下再查，避免查到旧值
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _check();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<bool?> _confirmClose({
    required String title,
    required String body,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          body,
          style: const TextStyle(
            fontSize: AppText.caption,
            height: 1.7,
            color: AppColors.sub,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('保持开启'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去系统里关'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PermissionReport? r = _report;
    final bool notifications = r?.notifications ?? false;
    final bool exactAlarms = r?.exactAlarms ?? false;
    final bool allGood = r?.allGood ?? false;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '通知与闹钟权限',
              style: TextStyle(
                fontSize: AppText.h2,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '两项都打开，提醒才准。开关显示的是手机系统里的真实状态。',
              style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            if (r == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...<Widget>[
              AppCard(
                child: Column(
                  children: <Widget>[
                    _permSwitch(
                      title: '通知',
                      desc: notifications
                          ? '已允许，到点会响'
                          : '没允许，到点不会有任何提示',
                      value: notifications,
                      onChanged: _busy ? null : _toggleNotifications,
                    ),
                    const AppDivider(),
                    _permSwitch(
                      title: '精确闹钟',
                      desc: exactAlarms
                          ? '已允许，提醒准点响'
                          : '没允许，提醒可能被推迟几分钟到几十分钟',
                      value: exactAlarms,
                      onChanged: _busy ? null : _toggleExactAlarms,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: allGood ? AppColors.successSoft : AppColors.warnSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      allGood
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: allGood ? AppColors.success : AppColors.warn,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        allGood
                            ? '两项都开好了，到点会准点提醒。'
                            : '还差一项没开，提醒可能不准。把上面没开的那一项打开即可。',
                        style: TextStyle(
                          fontSize: AppText.tiny,
                          height: 1.55,
                          color: allGood ? const Color(0xFF067647) : AppColors.warn,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '开关会跳到手机系统的设置页，因为 Android 不允许 App 自己改权限。'
                '改完返回这里会自动同步。\n'
                '到点提醒是闹钟式的：响铃 + 震动 + 全屏弹出，锁屏息屏都会亮屏。'
                '部分手机（小米、华为、OPPO、vivo 等）还需要在系统设置里打开'
                '「后台弹出界面」「锁屏显示」「自启动」，并把省电策略设为「不受限制」。',
                style: TextStyle(
                  fontSize: AppText.tiny,
                  height: 1.6,
                  color: AppColors.faint,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextButton(
                    onPressed: _busy ? null : _check,
                    child: Text(
                      _busy ? '处理中…' : '重新检查',
                      style: const TextStyle(fontSize: AppText.caption),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 一行「标题 + 说明 + 开关」
  Widget _permSwitch({
    required String title,
    required String desc,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: AppText.bodySm,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: AppText.tiny,
                    height: 1.45,
                    color: value ? AppColors.muted : AppColors.warn,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeTrackColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

/// 备份与恢复面板
///
/// 关键取舍：**导入只做一件事 —— 换手机恢复**。
/// 所以只认本 App 导出的 .json，不猜任何外来表格。理由是药名和剂量一旦被
/// 猜错，代价是吃错药；而「看数据」这件事，导出 CSV 已经解决了。
///
/// 导入的流程是「先预览，再写入」：
/// 选完文件先算出「会新增几种药、几条记录、跳过多少重复」，
/// 让用户看清后果再点确认，而不是点一下就闷头写库。
class _DataSheet extends StatefulWidget {
  const _DataSheet({required this.onImported});

  /// 导入成功后回调，用于刷新首页/记录页并重排提醒
  final Future<void> Function() onImported;

  @override
  State<_DataSheet> createState() => _DataSheetState();
}

class _DataSheetState extends State<_DataSheet> {
  bool _busy = false;

  Future<void> _import() async {
    setState(() => _busy = true);
    ({ImportPreview preview, String raw})? picked;
    try {
      picked = await BackupService.instance.pickAndPreview();
    } on BackupFormatException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _dialog(title: '这个文件用不了', body: e.message);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _dialog(title: '打不开这个文件', body: '文件可能已经损坏，或者没有读取权限。');
      debugPrint('[Import] 读取失败: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    // null = 用户在选文件时取消了，不打扰
    if (picked == null) return;
    final ImportPreview preview = picked.preview;

    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('从备份恢复'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              preview.summary,
              style: const TextStyle(
                fontSize: AppText.caption,
                height: 1.7,
                color: AppColors.sub,
              ),
            ),
            if (preview.exportedAt != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '备份时间：${_dateTimeText(preview.exportedAt!)}',
                style: const TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: preview.nothingToDo
                ? null
                : () => Navigator.of(ctx).pop(true),
            child: Text(preview.nothingToDo ? '无需导入' : '开始导入'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final ({int meds, int logs}) r =
          await BackupService.instance.importFromJson(picked.raw);
      await widget.onImported();
      if (!mounted) return;
      setState(() => _busy = false);
      _dialog(
        title: '导入完成',
        body: '新增 ${r.meds} 种药品、${r.logs} 条服药记录。\n\n'
            '已有的数据没有被改动。回到首页就能看到。',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _dialog(title: '导入失败', body: '写入时出错了，本机数据没有被改动。');
      debugPrint('[Import] 写入失败: $e');
    }
  }

  void _dialog({required String title, required String body}) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          body,
          style: const TextStyle(
            fontSize: AppText.caption,
            height: 1.75,
            color: AppColors.sub,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '备份与恢复',
              style: TextStyle(
                fontSize: AppText.h2,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '所有数据只存在这台手机上，不会上传。换手机前先导出一份备份。',
              style: TextStyle(fontSize: AppText.caption, height: 1.55, color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            AppCard(
              shadow: true,
              child: Column(
                children: <Widget>[
                  _actionRow(
                    icon: AppIcons.backup,
                    tone: AppIconTone.blue,
                    title: '导出完整备份',
                    desc: '药品 + 全部服药记录，存成一个文件',
                    onTap: _busy ? null : () => ExportFlow.backup(context),
                  ),
                  const AppDivider(),
                  _actionRow(
                    icon: AppIcons.restore,
                    tone: AppIconTone.green,
                    title: '从备份恢复',
                    desc: '在新手机上选这份文件，只补缺的，不覆盖已有的',
                    onTap: _busy ? null : _import,
                  ),
                  const AppDivider(),
                  _actionRow(
                    icon: AppIcons.table,
                    tone: AppIconTone.purple,
                    title: '导出服药记录表格',
                    desc: 'CSV，手机 WPS 就能打开看',
                    onTap: _busy ? null : () => ExportFlow.records(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warnSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(AppIcons.info, size: 18, color: AppColors.warn),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '卸载 App 会把本机数据一起删掉。换手机或重装前，务必先导出一份备份，'
                      '并把文件存到微信收藏或网盘里。',
                      style: TextStyle(
                        fontSize: AppText.tiny,
                        height: 1.6,
                        color: AppColors.warn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  '完成',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String title,
    required String desc,
    required VoidCallback? onTap,
    AppIconTone tone = AppIconTone.blue,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: <Widget>[
            Opacity(
              opacity: onTap == null ? 0.45 : 1,
              child: AppIconTile(icon, tone: tone),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: AppText.bodySm,
                      fontWeight: FontWeight.w500,
                      color: onTap == null ? AppColors.faint : AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    desc,
                    style: const TextStyle(
                      fontSize: AppText.tiny,
                      height: 1.45,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(AppIcons.chevron, size: 18, color: AppColors.faint)
            else
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }

  static String _dateTimeText(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// 开关行：左图标底板 + 标题/副标题 + iOS 风格开关
///
/// V1.4.0：替代原来的 `SwitchListTile.adaptive` —— 后者没有图标位，
/// 与同卡片里的导航行（有图标底板）视觉不对齐。
class _ToneSwitchTile extends StatelessWidget {
  const _ToneSwitchTile({
    required this.icon,
    required this.tone,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final AppIconTone tone;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: <Widget>[
            AppIconTile(icon, tone: tone),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: AppText.bodySm,
                      fontWeight: FontWeight.w500,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: AppText.tiny,
                      height: 1.45,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeTrackColor: AppColors.success,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「保持后台运行」行：电池优化白名单 + 排程自检
///
/// ═══════════════════════════════════════════════════════════════════
/// 为什么这一行是 V1.5.0 的关键（对应实测「后台/锁屏收不到提醒」）
/// ═══════════════════════════════════════════════════════════════════
///
/// 通知权限、精确闹钟、渠道配置全对，前台也确实收得到 —— 但 App 一旦
/// 切到后台/被杀，到点就没声音。这是 vivo/小米等 ROM 的「应用速冻/
/// 深度清理」在冻结进程时**连同取消它排的闹钟**。
///
/// 软件层能做的只有两件事：
/// 1. 请求「忽略电池优化」白名单（系统确认框，用户点允许）——
///    白名单里的 App，系统不再冻结、闹钟不被清除；
/// 2. 把「已排程 N 条、下一次几点」显示出来 —— 如果 N 明显比药次少，
///    说明排期被系统清了，用户就知道问题出在系统设置而不是 App。
class _BatteryRow extends StatefulWidget {
  const _BatteryRow();

  @override
  State<_BatteryRow> createState() => _BatteryRowState();
}

class _BatteryRowState extends State<_BatteryRow> with WidgetsBindingObserver {
  /// 是否已在电池优化白名单（null = 还没查完，先按已允许显示避免闪警告）
  bool? _whitelisted;

  /// 已排程的通知数量与最近一次时刻（排期自检）
  int _scheduledCount = 0;
  DateTime? _nextAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 用户从系统电池设置回来时重查一次真实状态
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final bool ok = await NativeBridge.isIgnoringBatteryOptimizations;
      final ({int count, DateTime? next}) st =
          await ReminderScheduler.instance.scheduleStatus();
      if (!mounted) return;
      setState(() {
        _whitelisted = ok;
        _scheduledCount = st.count;
        _nextAt = st.next;
      });
    } catch (_) {}
  }

  Future<void> _request() async {
    await NativeBridge.requestIgnoreBatteryOptimizations();
    // 系统确认框回来后 didChangeAppLifecycleState 会触发重查；
    // 这里再兜底查一次（部分 ROM 不发 resumed）
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _refresh();
  }

  String get _subtitle {
    final StringBuffer sb = StringBuffer();
    if (_whitelisted == true) {
      sb.write('已加入电池白名单，后台也能响');
    } else if (_whitelisted == false) {
      sb.write('没开的话，切后台或锁屏后提醒可能不响 —— 点这里允许');
    } else {
      sb.write('检查中…');
    }
    if (_scheduledCount > 0) {
      sb.write('；已排程 $_scheduledCount 条');
      final DateTime? n = _nextAt;
      if (n != null) {
        final String hh = n.hour.toString().padLeft(2, '0');
        final String mm = n.minute.toString().padLeft(2, '0');
        final bool today =
            n.year == DateTime.now().year && n.month == DateTime.now().month && n.day == DateTime.now().day;
        sb.write(today ? '，下一次 $hh:$mm' : '，下一次 ${n.month}月${n.day}日 $hh:$mm');
      }
    } else if (_scheduledCount == 0 && _whitelisted == true) {
      sb.write('；当前没有待响的提醒');
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final bool ok = _whitelisted != false;
    return AppCard(
      shadow: true,
      child: AppNavRow(
        icon: ok ? AppIcons.shield : AppIcons.warning,
        tone: ok ? AppIconTone.green : AppIconTone.orange,
        title: ok ? '保持后台运行' : '保持后台运行（重要）',
        subtitle: _subtitle,
        onTap: ok ? null : _request,
        showChevron: !ok,
      ),
    );
  }
}
