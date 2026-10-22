import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'medication_list_page.dart';
import 'settings_page.dart';

/// 底部四 Tab 容器
///
/// 用 IndexedStack 而不是每次重建：切回来时首页的滚动位置、
/// 记录页的选中日期都还在，用户不会「一切 Tab 就迷路」。
///
/// V2 相比 V1 多了一个「药品」Tab —— 试用反馈里「改药找不到入口」
/// 排在第一位，把它提到一级导航是最直接的解决方式。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  void _go(int i) {
    if (_index == i) return;
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: <Widget>[
            HomePage(
              onOpenHistory: () => _go(1),
              onOpenSettings: () => _go(3),
            ),
            const HistoryPage(),
            const _MedsTab(),
            const SettingsPage(),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(index: _index, onChanged: _go),
    );
  }
}

/// 药品 Tab 只是把管理页包一层 Scaffold 骨架：
/// 管理页本身带 AppBar（有「添加」按钮），这里不再重复包导航栏，
/// 只补一个 Tab 内的标题行。
class _MedsTab extends StatelessWidget {
  const _MedsTab();

  @override
  Widget build(BuildContext context) {
    return const MedicationListPage(embedded: true);
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const List<(IconData, String)> _items = <(IconData, String)>[
    (Icons.today_outlined, '今日'),
    (Icons.calendar_month_outlined, '记录'),
    (Icons.medication_outlined, '药品'),
    (Icons.person_outline_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < _items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          _items[i].$1,
                          size: 22,
                          color: index == i ? AppColors.primary : AppColors.faint,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _items[i].$2,
                          style: TextStyle(
                            fontSize: AppText.tab,
                            fontWeight:
                                index == i ? FontWeight.w600 : FontWeight.w400,
                            color: index == i ? AppColors.primary : AppColors.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
