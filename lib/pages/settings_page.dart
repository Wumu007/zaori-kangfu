import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/reminder_scheduler.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';
import 'family_view_page.dart';

/// 「我的」页（设置）
///
/// 这里只放四类东西：家属查看入口、影响提醒行为的设置、权限修复入口、免责声明。
/// 原则：每个开关都必须立刻生效，不做「设了但不生效」的假设置。
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
              padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 6, AppSpace.pageX, 12),
              child: Row(
                children: <Widget>[
                  const Text(
                    '我的',
                    style: TextStyle(
                      fontSize: AppText.h1,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${state.meds.length} 种药',
                    style: const TextStyle(
                      fontSize: AppText.caption,
                      color: AppColors.muted,
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
                  AppCard(
                    child: _NavRow(
                      icon: Icons.people_outline_rounded,
                      title: '家属查看',
                      subtitle: state.settings.guestPin == null
                          ? '本机查看（未设置查看密码）'
                          : '本机查看已开启 · 需 4 位密码',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const FamilyViewPage()),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gap),
                  AppCard(
                    child: Column(
                      children: <Widget>[
                        SwitchListTile.adaptive(
                          value: state.settings.largeText,
                          onChanged: state.settings.setLargeText,
                          activeTrackColor: AppColors.primary,
                          title: const Text(
                            '大字号',
                            style: TextStyle(
                              fontSize: AppText.bodySm,
                              fontWeight: FontWeight.w500,
                              color: AppColors.ink,
                            ),
                          ),
                          subtitle: const Text(
                            '整体放大 18%，看不清时再打开',
                            style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
                          ),
                        ),
                        const AppDivider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                '通知里「延后」多久',
                                style: TextStyle(
                                  fontSize: AppText.bodySm,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.ink,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                children: _snoozeOptions.map((int m) {
                                  final bool active = state.settings.snoozeMinutes == m;
                                  return GestureDetector(
                                    onTap: () => _onSnoozeChanged(m),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: active
                                            ? AppColors.primarySoft
                                            : AppColors.surface,
                                        borderRadius:
                                            BorderRadius.circular(AppRadius.badge),
                                      ),
                                      child: Text(
                                        '$m 分钟',
                                        style: TextStyle(
                                          fontSize: AppText.caption,
                                          fontWeight: active
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: active
                                              ? AppColors.primary
                                              : AppColors.sub,
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.gap),
                  AppCard(
                    child: _NavRow(
                      icon: state.notificationGranted
                          ? Icons.notifications_active_outlined
                          : Icons.notifications_off_outlined,
                      iconColor: state.notificationGranted
                          ? AppColors.success
                          : AppColors.warn,
                      title: '通知与闹钟权限',
                      subtitle: state.notificationGranted
                          ? '已允许，到点会响'
                          : '未允许，到点可能不响 —— 点这里去开',
                      onTap: () => _fixPermissions(context),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gap),
                  AppCard(
                    child: Column(
                      children: <Widget>[
                        _NavRow(
                          icon: Icons.description_outlined,
                          title: '免责声明',
                          subtitle: '本 App 只做提醒与记录',
                          onTap: () => _showDisclaimer(context),
                        ),
                        const AppDivider(),
                        _NavRow(
                          icon: Icons.storage_outlined,
                          title: '数据存储',
                          subtitle: '全部保存在本机，不上传、不需要登录',
                          onTap: () => _showStorageInfo(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Center(
                    child: Text(
                      '早日康复 v1.1.0 · 本地版',
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

  /// 延后时长改了要立刻重排通知，否则旧通知还是按老时长
  Future<void> _onSnoozeChanged(int minutes) async {
    final AppState state = AppState.instance;
    await state.settings.setSnoozeMinutes(minutes);
    await ReminderScheduler.instance.resync(state.meds);
  }

  /// 先尝试重新申请，被永久拒绝就跳系统设置
  Future<void> _fixPermissions(BuildContext context) async {
    final AppState state = AppState.instance;
    final bool granted = await ReminderScheduler.instance.requestPermissions();
    state.setNotificationGranted(granted);
    if (!granted) {
      await openAppSettings();
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(granted ? '通知权限已开启' : '请手动允许通知与闹钟权限')),
    );
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

  void _showStorageInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('数据存储'),
        content: const Text(
          '用药计划与服药记录只保存在这台手机上（本地数据库），不会上传服务器，也不需要注册账号。\n\n'
          '因此：卸载 App 或换手机，记录不会自动迁移。',
          style: TextStyle(
            fontSize: AppText.caption,
            height: 1.75,
            color: AppColors.sub,
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了')),
        ],
      ),
    );
  }
}

/// 带图标的一行入口
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor = AppColors.sub,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 12),
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
                    style: const TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.faint),
          ],
        ),
      ),
    );
  }
}
