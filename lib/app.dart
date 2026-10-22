import 'package:flutter/material.dart';

import 'pages/app_shell.dart';
import 'pages/ringing_page.dart';
import 'services/app_settings.dart';
import 'theme/app_theme.dart';

/// 全局导航入口
///
/// main.dart 的通知回调在 App 已经打开时（热启动）就要把响铃页 push
/// 出来 —— 必须有一个不依赖 context 的导航口。
class AppNav {
  AppNav._();

  /// 全局 navigator key：MaterialApp 上注册，任何地方都能 push
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// 打开响铃页（通知主体被点击时）。
  /// 用 pushNamed 走 routes 表，与冷启动的 initialRoute 是同一条注册项。
  static void openRinging(String payload) {
    navigatorKey.currentState
        ?.pushNamed('/ringing', arguments: payload);
  }
}

/// 应用根节点
///
/// 只做三件事：
/// 1. 装主题（AppTheme）；
/// 2. 把「大字号」开关接到全局 textScaler；
/// 3. 注册全局 navigatorKey + 响铃页路由 —— 通知点击无论冷启动还是
///    热启动都要能进响铃页。
class MedReminderApp extends StatelessWidget {
  const MedReminderApp({super.key, this.initialRingingPayload});

  /// 冷启动来自「到点服药提醒」通知时的 payload；普通启动为 null
  final String? initialRingingPayload;

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
          navigatorKey: AppNav.navigatorKey,
          builder: (BuildContext context, Widget? child) {
            final MediaQueryData mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(settings.textScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          // 冷启动直接进响铃页（锁屏上 fullScreenIntent 拉起的场景）。
          // 统一走 onGenerateRoute：热启动 pushNamed 的 arguments 与
          // 冷启动 initialRoute 的兜底 payload 都在这里取。
          initialRoute:
              initialRingingPayload == null ? null : '/ringing',
          onGenerateRoute: (RouteSettings s) {
            if (s.name == '/ringing') {
              // 热启动：arguments 是 payload；冷启动：arguments 为空，
              // 落到 initialRingingPayload
              final String arg = s.arguments is String
                  ? s.arguments as String
                  : (initialRingingPayload ?? '');
              return MaterialPageRoute<void>(
                builder: (_) => RingingPage(payload: arg),
                settings: s,
              );
            }
            return null;
          },
          home: const AppShell(),
        );
      },
    );
  }
}
