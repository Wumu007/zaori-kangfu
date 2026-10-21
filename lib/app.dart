import 'package:flutter/material.dart';

import 'pages/app_shell.dart';
import 'services/app_settings.dart';
import 'theme/app_theme.dart';

/// 应用根节点
///
/// 只做两件事：
/// 1. 装主题（AppTheme）；
/// 2. 把「大字号」开关接到全局 textScaler —— 一处控制，所有页面同步，
///    而不是在每个页面里散落 if (largeText) fontSize += 4。
class MedReminderApp extends StatelessWidget {
  const MedReminderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (BuildContext context, _) {
        return MaterialApp(
          title: '早日康复',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          builder: (BuildContext context, Widget? child) {
            final MediaQueryData mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(settings.textScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const AppShell(),
        );
      },
    );
  }
}
