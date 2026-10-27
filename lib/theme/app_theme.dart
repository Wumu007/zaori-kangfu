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

  // ═══════════════════════════════════════════════════════════════
  // V1.14.0：整体视觉换成「柔紫 + 白卡」
  // ═══════════════════════════════════════════════════════════════
  //
  // 参考用户给的设计：淡紫底 + 纯白大圆角卡片 + 柔和紫调投影 +
  // 粉彩图标块。相对上一版的 iOS 灰白风，这套更「轻、柔、有空气感」，
  // 主要变化是：
  // 1. 主色从亮蓝 #2F5BF6 换成靛紫 #5B57F0（紫比蓝更沉稳，也不刺眼）；
  // 2. 页面底色改成带一点紫的浅灰紫，卡片纯白才「浮」得起来；
  // 3. 分割线与描边全部调淡，层次交给投影而不是线条。
  static const Color primary = Color(0xFF5B57F0); // 主色：按钮、选中态
  static const Color primaryDeep = Color(0xFF3E3AD8); // 主色深：渐变末端、按下态
  static const Color primarySoft = Color(0xFFEDEBFF); // 主色浅底：图标底、提示卡
  static const Color success = Color(0xFF12B76A); // 已服用
  static const Color successSoft = Color(0xFFE8F7EF); // 已服用浅底
  static const Color warn = Color(0xFFB54708); // 到点未服 / 低置信度文字
  static const Color warnSoft = Color(0xFFFFF6EC); // 到点未服 / 低置信度底
  static const Color danger = Color(0xFFB42318); // 删除等破坏性动作

  static const Color ink = Color(0xFF14142B); // 主文字（带一点紫的深灰）
  static const Color sub = Color(0xFF5F6178); // 次文字
  static const Color muted = Color(0xFF8B8DA3); // 辅助文字、字段名
  static const Color faint = Color(0xFFA9ABC0); // 更弱的说明文字

  static const Color line = Color(0xFFEFEEF8); // 卡片描边
  static const Color divider = Color(0xFFF3F2FA); // 列表分隔线
  static const Color surface = Color(0xFFF7F6FD); // 浅紫灰底（转写卡、胶囊底）
  static const Color bg = Color(0xFFFFFFFF); // 卡片/页面底色

  // ---- 渐变底（页面背景） ----

  /// 页面顶部：略深的浅紫
  static const Color pageTop = Color(0xFFEFECFE);

  /// 页面底部：几乎纯白，让内容区干净
  static const Color pageBottom = Color(0xFFFAF9FF);

  /// 分组页面底色（子页面 Scaffold 用，和渐变底色对齐）
  static const Color groupedBg = Color(0xFFF4F2FD);

  /// 发丝分割线：0.5px
  static const Color hairline = Color(0xFFECEBF5);

  /// 毛玻璃底层色（配合 BackdropFilter 用）
  static const Color glassTint = Color(0xF7FFFFFF);

  /// 图标底色板：粉彩系（参考稿里的紫 / 蓝 / 橙 / 粉 / 青）
  static const Color iconBlueBg = Color(0xFFE8EEFF);
  static const Color iconGreenBg = Color(0xFFE6F8F0);
  static const Color iconOrangeBg = Color(0xFFFFEFE0);
  static const Color iconPurpleBg = Color(0xFFEFEAFF);
  static const Color iconGrayBg = Color(0xFFF1F0F8);
  static const Color iconPinkBg = Color(0xFFFDEAF4);
  static const Color iconCyanBg = Color(0xFFE4F7FB);
}

/// 阴影与渐变
///
/// 统一在这里定义，页面里不要各写各的 —— 参考稿那种「卡片轻轻浮起来」
/// 的感觉，全靠投影的颜色和扩散范围一致。
class AppShadow {
  AppShadow._();

  /// 卡片投影：紫调、大扩散、低透明度。
  /// 用黑色投影会显脏，紫调投影才和底色是一家人。
  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(
      color: Color(0x0D4B3FB5),
      blurRadius: 22,
      offset: Offset(0, 8),
    ),
  ];

  /// 更轻的投影：内嵌小卡、分组内的次级卡片
  static const List<BoxShadow> soft = <BoxShadow>[
    BoxShadow(
      color: Color(0x0A4B3FB5),
      blurRadius: 14,
      offset: Offset(0, 5),
    ),
  ];

  /// 悬浮元素（底部导航、悬浮按钮）
  static const List<BoxShadow> float = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A5348C8),
      blurRadius: 28,
      offset: Offset(0, 10),
    ),
  ];

  /// 页面渐变底色
  static const LinearGradient page = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[AppColors.pageTop, AppColors.pageBottom],
  );

  /// 主按钮渐变
  static const LinearGradient primaryButton = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF6E6AF8), AppColors.primaryDeep],
  );
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

  static const double card = 20; // 卡片（参考稿的大圆角）
  static const double cardSm = 16; // 小卡片、内嵌块
  static const double button = 14; // 按钮
  static const double pill = 999; // 完全胶囊
  static const double badge = 8; // 徽标
  static const double iconTile = 13; // 图标底板
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
