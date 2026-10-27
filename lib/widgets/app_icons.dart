import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// ============================================================================
/// 统一风格图标体系（V1.4.0 新增）
///
/// ---------------------------------------------------------------------------
/// 为什么要专门做一层，而不是各页面直接 Icon(...)
/// ---------------------------------------------------------------------------
/// 上一版的问题是：药品用 `Icons.medication`、提醒用 `Icons.alarm`、
/// 记录用 `Icons.history`、导出用 `Icons.file_download`，但它们的
/// **粗细、视觉重量、是否有圆角端点**各不相同 —— Material 图标里
/// 有些是 outlined、有些是 rounded、有些是 filled，混在一起时
/// 一眼就能看出「拼凑感」。
///
/// iOS 的观感来自两点：
/// 1. **统一线宽 + 统一形状语言**（SF Symbols 全部是 2pt 左右线宽、
///    圆角端点、圆角转折）；
/// 2. **图标装在带柔和的浅色圆角底板里**（Settings 列表那种）。
///
/// 所以这层做两件事：
/// - [AppIcons]：把所有业务图标的「选型」集中一处，
///   统一用 `_rounded` 变体（Material 里最接近 SF Symbols 的一族）；
/// - [AppIconTile]：把图标放进柔和底板，形成 iOS 设置页那种
///   「彩色圆角方块 + 白色符号」的识别感。
/// ============================================================================

/// 业务图标选型表
///
/// 规则：**全部用 rounded 变体**，线宽通过 [AppIcon] 统一控制。
/// 新增功能时在这里加一条，不要在页面里直接写 Icons.xxx —— 否则
/// 下一个人又会混进 outlined 图标。
class AppIcons {
  AppIcons._();

  // ---- 药品 / 提醒 ----
  static const IconData medication = Icons.medication_rounded;
  static const IconData pill = Icons.medication_liquid_rounded;
  static const IconData reminder = Icons.alarm_rounded;
  static const IconData reminderOff = Icons.alarm_off_rounded;
  static const IconData schedule = Icons.schedule_rounded;
  static const IconData repeat = Icons.repeat_rounded;
  static const IconData calendar = Icons.calendar_today_rounded;

  // ---- 记录 / 统计 ----
  static const IconData history = Icons.history_rounded;
  static const IconData stats = Icons.insights_rounded;
  static const IconData check = Icons.check_circle_rounded;
  static const IconData checkOutline = Icons.check_circle_outline_rounded;
  static const IconData skip = Icons.remove_circle_outline_rounded;
  static const IconData snooze = Icons.snooze_rounded;
  static const IconData warning = Icons.error_outline_rounded;

  // ---- 数据 / 导出 ----
  static const IconData exportFile = Icons.ios_share_rounded;
  static const IconData importFile = Icons.download_rounded;
  static const IconData backup = Icons.cloud_upload_outlined;
  static const IconData restore = Icons.restore_rounded;
  static const IconData table = Icons.table_chart_rounded;
  static const IconData document = Icons.description_rounded;

  // ---- 输入 ----
  static const IconData mic = Icons.mic_rounded;
  static const IconData micOff = Icons.mic_off_rounded;
  static const IconData keyboard = Icons.keyboard_rounded;
  static const IconData voice = Icons.graphic_eq_rounded;

  // ---- 设置 / 权限 ----
  static const IconData settings = Icons.settings_rounded;
  static const IconData notification = Icons.notifications_active_rounded;
  static const IconData shield = Icons.verified_user_rounded;
  static const IconData storage = Icons.folder_rounded;
  static const IconData text = Icons.text_fields_rounded;
  static const IconData info = Icons.info_outline_rounded;

  // ---- 导航 ----
  static const IconData back = Icons.arrow_back_ios_new_rounded;
  static const IconData forward = Icons.arrow_forward_ios_rounded;
  static const IconData chevron = Icons.chevron_right_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData add = Icons.add_rounded;
  static const IconData undo = Icons.undo_rounded;
  static const IconData edit = Icons.edit_rounded;
  static const IconData delete = Icons.delete_outline_rounded;

  // ---- 底部 Tab（选中/未选中用同一族，只切换 filled/outlined）----
  static const IconData tabToday = Icons.today_rounded;
  static const IconData tabHistory = Icons.history_rounded;
  static const IconData tabMeds = Icons.medication_rounded;
  static const IconData tabMe = Icons.person_rounded;
}

/// 图标底板配色方案
///
/// iOS 设置页每个图标都有底色，但底色和图标语义相关：
/// 药品偏蓝、已完成偏绿、提醒偏橙、数据偏紫、中性偏灰。
enum AppIconTone { blue, green, orange, purple, gray, red }

/// 单个图标（统一尺寸与颜色）
///
/// 不要直接用它画「功能入口」—— 那种场景用 [AppIconTile]。
/// [AppIcon] 适合行内小图标（勾、箭头、状态标记）。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size = 20,
    this.color = AppColors.sub,
  });

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: size, color: color);
  }
}

/// 带柔和底板的圆角图标块（iOS 设置列表观感）
///
/// [size] 指底板边长，图标本身自动取 [size] * 0.52，
/// 保证不同底板尺寸下的视觉重量一致。
class AppIconTile extends StatelessWidget {
  const AppIconTile(
    this.icon, {
    super.key,
    this.tone = AppIconTone.blue,
    this.size = 36,
    this.filled = false,
  });

  final IconData icon;
  final AppIconTone tone;
  final double size;

  /// true = 实心彩色底 + 白色图标（更醒目，用于主导航/强调项）
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color bg) = _colors(tone);
    // V1.14.0：底色改成「同色系微渐变」。
    // 纯平面色块在浅紫底上显得单薄；从浅到底一点点过渡，
    // 图标块就有了厚度，和参考稿的质感一致（代价只有一层渐变，无性能影响）。
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: filled
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[fg.withOpacity(0.88), fg],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[bg, Color.lerp(bg, Colors.white, 0.45)!],
              ),
        borderRadius: BorderRadius.circular(size * 0.32),
        // 内嵌一层极淡白边，浅底上能勾出边界（参考稿的玻璃感）
        border: Border.all(
          color: filled ? Colors.white.withOpacity(0.18) : Colors.white,
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: size * 0.52,
        color: filled ? Colors.white : fg,
      ),
    );
  }

  static (Color, Color) _colors(AppIconTone tone) {
    switch (tone) {
      case AppIconTone.blue:
        return (AppColors.primary, AppColors.iconBlueBg);
      case AppIconTone.green:
        return (AppColors.success, AppColors.iconGreenBg);
      case AppIconTone.orange:
        return (AppColors.warn, AppColors.iconOrangeBg);
      case AppIconTone.purple:
        return (const Color(0xFF6B4EF5), AppColors.iconPurpleBg);
      case AppIconTone.red:
        return (AppColors.danger, const Color(0xFFFDECEA));
      case AppIconTone.gray:
        return (AppColors.sub, AppColors.iconGrayBg);
    }
  }
}

/// 毛玻璃容器（iOS vibrancy 观感）
///
/// 用 [BackdropFilter] + 半透明白，模拟 iOS 的模糊材质。
/// 注意：使用范围要克制 —— 只在「浮在内容上」的元素上用
/// （底部 Tab 栏、悬浮操作条），否则会明显掉帧：
/// BackdropFilter 每一帧都要重新采样背景像素。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.blur = 18,
    this.tint = AppColors.glassTint,
    this.borderRadius,
    this.border,
  });

  final Widget child;
  final double blur;
  final Color tint;
  final BorderRadius? borderRadius;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius =
        borderRadius ?? BorderRadius.circular(AppRadius.card);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: radius,
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 分组标题（iOS insetGrouped 的 section header）
///
/// 小号、全大写西文风格不适合中文，所以这里用「弱化的小字 + 左缩进」，
/// 保持信息层级而不引入违和感。
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.text, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(18, 0, 18, 8),
  });

  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          // V1.14.0：左侧加一小段主色竖条，分组标题不再和正文糊在一起
          Container(
            width: 3,
            height: 12,
            margin: const EdgeInsets.only(right: 7),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0xFF8A86FF), AppColors.primary],
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: AppText.caption,
                fontWeight: FontWeight.w600,
                color: AppColors.sub,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// iOS 风格的功能行（图标 + 标题 + 副标题 + 右箭头）
///
/// 把「设置页那种一行一个功能」的重复结构收成一处，
/// 保证图标底板尺寸、行高、分隔线缩进在各页完全一致。
class AppNavRow extends StatelessWidget {
  const AppNavRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.tone = AppIconTone.blue,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final AppIconTone tone;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  /// 破坏性动作：标题用红色
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: <Widget>[
              AppIconTile(icon, tone: danger ? AppIconTone.red : tone),
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
                        color: danger ? AppColors.danger : AppColors.ink,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: AppText.tiny,
                          height: 1.45,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
              if (showChevron) ...<Widget>[
                const SizedBox(width: 6),
                const Icon(
                  AppIcons.chevron,
                  size: 18,
                  color: AppColors.faint,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
