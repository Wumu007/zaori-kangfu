import 'package:flutter/material.dart';

/// ============================================================================
/// 设计 token（与画布「通用版」界面一一对应）
///
/// 为什么单独抽一层：界面改版时只改这里，页面代码不用动。
/// 色值来自设计稿：主色 #2F5BF6、成功 #12B76A、警示 #B54708/#FFF7ED。
/// ============================================================================

/// 颜色
///
/// V1.4.0 改版：在保留主色体系的前提下，向 iOS 的「系统色 + 中性灰阶」靠拢。
/// 关键是两点：
/// 1. 背景分层更明显（iOS 用 systemGroupedBackground 衬托卡片），
///    卡片纯白 + 更淡的描边，视觉上「浮」在灰底上；
/// 2. 分割线极细（0.5px 发丝线），接近 iOS 的 separator。
class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF2F5BF6); // 主色：按钮、选中态
  static const Color primarySoft = Color(0xFFEFF3FF); // 主色浅底：图标底、提示卡
  static const Color success = Color(0xFF12B76A); // 已服用
  static const Color successSoft = Color(0xFFE8F7EF); // 已服用浅底
  static const Color warn = Color(0xFFB54708); // 到点未服 / 低置信度文字
  static const Color warnSoft = Color(0xFFFFF7ED); // 到点未服 / 低置信度底
  static const Color danger = Color(0xFFB42318); // 删除等破坏性动作

  static const Color ink = Color(0xFF131A26); // 主文字
  static const Color sub = Color(0xFF6B7688); // 次文字
  static const Color muted = Color(0xFF8A94A6); // 辅助文字、字段名
  static const Color faint = Color(0xFFA6AEBD); // 更弱的说明文字

  static const Color line = Color(0xFFEDEFF2); // 卡片描边
  static const Color divider = Color(0xFFF1F3F5); // 列表分隔线
  static const Color surface = Color(0xFFF7F8FA); // 浅灰底（转写卡、胶囊底）
  static const Color bg = Color(0xFFFFFFFF); // 卡片/页面底色

  // ---- V1.4.0 iOS 风格补充 ----

  /// 分组页面底色（iOS systemGroupedBackground 浅色版）
  /// 比 surface 再淡一点，让白卡片能"浮"起来
  static const Color groupedBg = Color(0xFFF2F4F7);

  /// 发丝分割线：0.5px，iOS separator 的观感
  static const Color hairline = Color(0xFFE5E8EC);

  /// 毛玻璃底层色（配合 BackdropFilter 用）
  static const Color glassTint = Color(0xF2FFFFFF);

  /// 图标底色板：给不同功能小图标一套统一的柔和底色
  static const Color iconBlueBg = Color(0xFFEAF0FF);
  static const Color iconGreenBg = Color(0xFFE9F8F0);
  static const Color iconOrangeBg = Color(0xFFFFF2E5);
  static const Color iconPurpleBg = Color(0xFFF1EDFF);
  static const Color iconGrayBg = Color(0xFFF0F2F5);
}

/// 字号
///
/// 说明：这里是「标准字号」，比上一版适老稿整体小 4~6px。
/// 需要更大的用户请在「我的 → 大字号」里开启，全局统一放大，
/// 而不是在页面里散落大字号码 —— 这样默认用户不会觉得界面粗糙。
class AppText {
  AppText._();

  static const double h1 = 22; // 页面标题「今天」
  static const double h2 = 17; // 卡片主信息、导航标题
  static const double body = 16; // 按钮、确认页字段值
  static const double bodySm = 15; // 列表时间、进度标题
  static const double meta = 14; // 次按钮、说明
  static const double caption = 13; // 字段名、辅助说明
  static const double tiny = 12; // 徽标、脚注
  static const double tab = 11; // 底部 Tab 文字

  // ---- V1.4.0 iOS 风格：大标题（iOS Large Title） ----
  static const double largeTitle = 32;
  static const double title2 = 20;
}

/// 圆角与间距
///
/// V1.4.0 向 iOS 靠：卡片圆角加大（14 → 18），按钮改为连续圆角胶囊。
class AppRadius {
  AppRadius._();

  static const double card = 18; // 卡片（iOS insetGrouped 风格）
  static const double cardSm = 14; // 小卡片、内嵌块
  static const double button = 14; // 按钮
  static const double pill = 999; // 完全胶囊
  static const double badge = 8; // 徽标
  static const double iconTile = 12; // 图标底板
}

class AppSpace {
  AppSpace._();

  static const double pageX = 20; // 页面左右安全边距
  static const double gap = 14; // 模块间距
  static const double gapLg = 22; // 大模块间距（iOS 更爱留白）
  static const double sectionTop = 28; // 分组标题上方留白
}

/// 全局 ThemeData
class AppTheme {
  AppTheme._();

  static ThemeData build() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      surface: AppColors.bg,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // V1.4.0：页面底色改为 iOS 分组灰，卡片用纯白衬托层次
      scaffoldBackgroundColor: AppColors.groupedBg,
      splashFactory: InkSparkle.splashFactory,
      // 中文字体走系统（Android: Noto Sans CJK / iOS: PingFang），
      // 不打包字体文件，APK 体积小，且各机型字形自然。
      fontFamilyFallback: const <String>[
        'Noto Sans SC',
        'PingFang SC',
        'Microsoft YaHei',
      ],
      textTheme: const TextTheme(
        titleLarge: TextStyle(
          fontSize: AppText.h1,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        titleMedium: TextStyle(
          fontSize: AppText.h2,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        bodyMedium: TextStyle(fontSize: AppText.meta, color: AppColors.sub),
        bodySmall: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
      ),
      // 统一 AppBar：白底、无阴影、16px 标题
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.groupedBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: AppColors.ink,
        titleTextStyle: TextStyle(
          fontSize: AppText.h2,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        contentTextStyle: TextStyle(fontSize: AppText.meta, color: Colors.white),
        // iOS 观感：更大的圆角 + 轻微阴影
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.hairline,
        thickness: 0.5, // 发丝线
        space: 0.5,
      ),
      // 底部弹层统一 iOS 观感：大圆角 + 白底
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: true,
        dragHandleColor: Color(0x33000000),
        dragHandleSize: Size(36, 4),
      ),
      // 对话框：iOS 风格圆角 20
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        titleTextStyle: TextStyle(
          fontSize: AppText.h2,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
      ),
      // 列表项：iOS 的 44+ 行高、紧凑内边距
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.sub,
        titleTextStyle: TextStyle(fontSize: AppText.bodySm, color: AppColors.ink),
        subtitleTextStyle: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
        contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        minLeadingWidth: 28,
      ),
    );
  }
}
