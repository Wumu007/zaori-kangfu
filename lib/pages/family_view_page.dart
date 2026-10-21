import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/day_slot.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

/// 家属查看页
///
/// 这里刻意把两条路径摆在同一屏，因为它们的成本差别巨大，用户需要知道：
///
/// A. 本机查看（V1 已实现）—— 家人用**这台手机**看，免登录。
///    入口 = 首页右上角「家属」图标；4 位查看密码只是防误改，不是账号鉴权。
///    数据范围 = 本机今天与近 7 天，只读，不能改计划、不能打卡、不能删除。
///
/// B. 邀请家人（V3）—— 家人在**自己的手机**装 App 并登录同一账号。
///    数据范围 = 全部历史 + 依从率 + 漏服推送，需要云同步与服务端。
///    因此 V1 只做入口预告，不做假按钮。
class FamilyViewPage extends StatelessWidget {
  const FamilyViewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          // 设置里的访客密码变化也要刷新本页，所以两个 notifier 一起听
          animation: Listenable.merge(<Listenable>[state, state.settings]),
          builder: (BuildContext context, _) {
            final bool hasPin = state.settings.guestPin != null &&
                state.settings.guestPin!.isNotEmpty;
            return Column(
              children: <Widget>[
                SimpleNavBar(
                  title: '家属查看',
                  onBack: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.pageX,
                      4,
                      AppSpace.pageX,
                      24,
                    ),
                    children: <Widget>[
                      const Text(
                        '家人能看到你的服药情况，但改不了你的用药计划。',
                        style: TextStyle(
                          fontSize: AppText.caption,
                          height: 1.6,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _PreviewCard(state: state),
                      const SizedBox(height: 18),
                      const Text(
                        '查看方式',
                        style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                      ),
                      const SizedBox(height: 8),
                      _ModeTile(
                        icon: Icons.phone_iphone_rounded,
                        iconBg: AppColors.primarySoft,
                        iconColor: AppColors.primary,
                        title: '本机查看（免登录）',
                        desc: '把手机递给家人，或用 4 位查看密码进入访客视图。'
                            '只能看这台手机的今天与近 7 天记录，不能改计划、不能删记录。',
                        onTap: () => hasPin
                            ? _openGuest(context)
                            : _setPin(context),
                      ),
                      const SizedBox(height: 10),
                      _ModeTile(
                        icon: Icons.person_add_alt_1_rounded,
                        iconBg: AppColors.successSoft,
                        iconColor: const Color(0xFF067647),
                        title: '邀请家人（需登录同一账号）',
                        desc: '家人用自己的手机安装 App 并登录同一账号，可看全部历史与依从率，'
                            '并收到「未打卡」提醒。需开启云同步、需联网。',
                        onTap: () => _showV3Dialog(context),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'V1 只做本机查看，账号与云同步排在 V3。',
                        style: TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: Column(
                    children: <Widget>[
                      PrimaryButton(
                        label: hasPin ? '进入访客视图' : '设置 4 位查看密码',
                        onPressed: hasPin
                            ? () => _openGuest(context)
                            : () => _setPin(context),
                      ),
                      const SizedBox(height: 12),
                      if (hasPin)
                        TextButton(
                          onPressed: () => _clearPin(context),
                          child: const Text(
                            '关闭访客视图（清除密码）',
                            style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                          ),
                        )
                      else
                        const Text(
                          '设置后，把手机递给家人时会先要密码，避免误点打卡。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // --- 交互 -----------------------------------------------------------------

  Future<void> _setPin(BuildContext context) async {
    final String? pin = await _askPin(
      context,
      title: '设置查看密码',
      hint: '家人查看时输入这 4 位数字',
      confirmLabel: '保存',
    );
    if (pin == null) return;
    await AppState.instance.settings.setGuestPin(pin);
  }

  Future<void> _clearPin(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('关闭访客视图？'),
        content: const Text(
          '清除密码后，家人将无法再通过访客视图查看记录。',
          style: TextStyle(fontSize: AppText.caption, height: 1.6),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('清除')),
        ],
      ),
    );
    if (ok == true) await AppState.instance.settings.setGuestPin(null);
  }

  Future<void> _openGuest(BuildContext context) async {
    final String? pin = await _askPin(
      context,
      title: '输入查看密码',
      hint: '4 位数字',
      confirmLabel: '进入',
    );
    if (pin == null) return;
    if (!AppState.instance.settings.verifyPin(pin)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码不对，再试一次')),
      );
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const GuestViewPage()),
    );
  }

  Future<void> _showV3Dialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('邀请家人（V3 开放）'),
        content: const Text(
          '这条路径需要账号与云同步：家人装上 App 并登录同一账号后，'
          '才能在自己手机上看你的记录、收到未打卡提醒。\n\n'
          'V1 是纯本地存储，没有账号体系，所以暂时只提供上一行的「本机查看」。',
          style: TextStyle(fontSize: AppText.caption, height: 1.7, color: AppColors.sub),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 通用的 4 位数字输入框
  Future<String?> _askPin(
    BuildContext context, {
    required String title,
    required String hint,
    required String confirmLabel,
  }) async {
    final TextEditingController controller = TextEditingController();
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              hint,
              style: const TextStyle(fontSize: AppText.caption, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                letterSpacing: 8,
                fontWeight: FontWeight.w600,
              ),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(
                counterText: '',
                hintText: '••••',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final String text = controller.text.trim();
              if (text.length != 4) return;
              Navigator.of(ctx).pop(text);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }
}

/// 状态预览卡：把访客将要看到的东西，先给本人看一遍
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final List<DaySlot> slots = state.todaySlots;
    final DateTime now = DateTime.now();
    final String hm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    return AppCard(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '本机 · 今天',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
              ),
              const Spacer(),
              Text(
                '$hm 更新',
                style: const TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            slots.isEmpty
                ? '今天没有用药计划'
                : '${slots.length} 次计划 · 已完成 ${state.todayDone} 次',
            style: const TextStyle(
              fontSize: AppText.h2,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
          if (slots.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: slots.map((DaySlot s) {
                final bool done = s.taken;
                final bool isLate = s.overdue(now) && !s.taken && !s.skipped;
                return SoftBadge(
                  text: '${s.hm} ${done ? '已服' : isLate ? '未服' : '待服'}',
                  foreground: done
                      ? const Color(0xFF067647)
                      : isLate
                          ? AppColors.warn
                          : AppColors.sub,
                  background: done
                      ? AppColors.successSoft
                      : isLate
                          ? AppColors.warnSoft
                          : AppColors.surface,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// 查看方式卡片
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    required this.desc,
    required this.onTap,
  });

  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: AppText.meta,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      desc,
                      style: const TextStyle(
                        fontSize: AppText.tiny,
                        height: 1.58,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 家属访客视图（只读）
///
/// 只做两件事：看今天、看近 7 天。
/// 没有打钩按钮、没有编辑入口 —— 权限边界写在界面上，而不是写在文档里。
class GuestViewPage extends StatelessWidget {
  const GuestViewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) {
            final DateTime now = DateTime.now();
            final DateTime today = DateTime(now.year, now.month, now.day);
            final List<DaySlot> slots = state.todaySlots;

            return Column(
              children: <Widget>[
                SimpleNavBar(
                  title: '今日服药情况',
                  onBack: () => Navigator.of(context).pop(),
                  trailing: SoftBadge(
                    text: '只读',
                    foreground: AppColors.sub,
                    background: AppColors.surface,
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.pageX,
                      4,
                      AppSpace.pageX,
                      24,
                    ),
                    children: <Widget>[
                      _readOnlyBanner(),
                      const SizedBox(height: 14),
                      if (slots.isEmpty)
                        const EmptyState(
                          icon: Icons.inbox_outlined,
                          title: '今天没有用药计划',
                          message: '本人添加药品后，这里会显示到点时间与是否已服用。',
                        )
                      else
                        AppCard(
                          child: Column(
                            children: <Widget>[
                              for (int i = 0; i < slots.length; i++) ...<Widget>[
                                if (i > 0) const AppDivider(),
                                _guestRow(slots[i], now),
                              ],
                            ],
                          ),
                        ),
                      const SizedBox(height: 18),
                      const Text(
                        '近 7 天',
                        style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                      ),
                      const SizedBox(height: 8),
                      AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          children: List<Widget>.generate(7, (int i) {
                            final DateTime day = today.subtract(Duration(days: i));
                            final List<DaySlot> ds = state.slotsOf(day);
                            final int done = ds.where((DaySlot s) => s.taken).length;
                            final int missed = state.missedOf(day);
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 9),
                              child: Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 84,
                                    child: Text(
                                      i == 0
                                          ? '今天'
                                          : '${day.month}/${day.day}',
                                      style: const TextStyle(
                                        fontSize: AppText.caption,
                                        color: AppColors.sub,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      ds.isEmpty
                                          ? '无计划'
                                          : '已服 $done/${ds.length}'
                                              '${missed > 0 ? ' · 漏服 $missed' : ''}',
                                      style: TextStyle(
                                        fontSize: AppText.caption,
                                        color: missed > 0
                                            ? AppColors.warn
                                            : ds.isEmpty
                                                ? AppColors.faint
                                                : AppColors.ink,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _readOnlyBanner() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.visibility_outlined, size: 18, color: AppColors.muted),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '家属访客视图：只能查看，不能打卡、不能改计划。数据只在这台手机上。',
                style: TextStyle(
                  fontSize: AppText.tiny,
                  height: 1.55,
                  color: AppColors.muted,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _guestRow(DaySlot slot, DateTime now) {
    final bool done = slot.taken;
    final bool isLate = slot.overdue(now) && !slot.taken && !slot.skipped;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              slot.hm,
              style: const TextStyle(
                fontSize: AppText.meta,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              slot.med.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: AppText.bodySm, color: AppColors.ink),
            ),
          ),
          SoftBadge(
            text: done ? '已服用' : isLate ? '未服' : '待服',
            foreground: done
                ? const Color(0xFF067647)
                : isLate
                    ? AppColors.warn
                    : AppColors.muted,
            background: done
                ? AppColors.successSoft
                : isLate
                    ? AppColors.warnSoft
                    : AppColors.surface,
          ),
        ],
      ),
    );
  }
}
