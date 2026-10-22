import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
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

  /// V1.4.0：全部换成 rounded 族，选中/未选中只切换同一族的两态，
  /// 不再出现「outlined 和 rounded 混用」的割裂感。
  static const List<(IconData, IconData, String)> _items =
      <(IconData, IconData, String)>[
    (AppIcons.tabToday, Icons.today_outlined, '今日'),
    (AppIcons.history, Icons.history_outlined, '记录'),
    (AppIcons.tabMeds, Icons.medication_outlined, '药品'),
    (AppIcons.tabMe, Icons.person_outline_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    // iOS 观感：半透明 + 毛玻璃 + 极细顶部分隔线
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xF7FFFFFF),
            border: Border(top: BorderSide(color: AppColors.hairline, width: 0.5)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 56,
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < _items.length; i++)
                    Expanded(
                      child: InkResponse(
                        onTap: () => onChanged(i),
                        radius: 34,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Icon(
                              index == i ? _items[i].$1 : _items[i].$2,
                              size: 23,
                              color: index == i
                                  ? AppColors.primary
                                  : AppColors.faint,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _items[i].$3,
                              style: TextStyle(
                                fontSize: AppText.tab,
                                fontWeight: index == i
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: index == i
                                    ? AppColors.primary
                                    : AppColors.faint,
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
        ),
      ),
    );
  }
}
