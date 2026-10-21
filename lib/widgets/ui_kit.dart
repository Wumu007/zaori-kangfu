import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// ============================================================================
/// 通用小组件
///
/// 抽出来的目的不是「复用几个 Container」，而是让圆角、描边、间距、
/// 按压反馈在全局只有一份定义 —— 改版时不用满项目找 14 和 16。
/// ============================================================================

/// 白底卡片：1px 描边 + 14 圆角（设计稿里的分组卡）
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.clip = true,
    this.color = AppColors.bg,
  });

  final Widget child;
  final EdgeInsets padding;

  /// 内部有分隔线时建议裁剪，避免第一行/最后一行露头
  final bool clip;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: child,
    );
  }
}

/// 列表分隔线：左侧缩进 16，和卡片内边距对齐
class AppDivider extends StatelessWidget {
  const AppDivider({super.key, this.indent = 16});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: EdgeInsets.only(left: indent),
      color: AppColors.divider,
    );
  }
}

/// 主按钮：高度 50、圆角 14，禁用时降透明度（不改成灰色，避免看起来像不可点）
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.height = 50,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bool active = enabled && onPressed != null;
    return Opacity(
      opacity: active ? 1 : 0.4,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Material(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.button),
            onTap: active ? onPressed : null,
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: AppText.body,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 描边胶囊（首页「语音添加」、确认页次级操作）
class GhostPill extends StatelessWidget {
  const GhostPill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.color = AppColors.primary,
    this.background = AppColors.primarySoft,
    this.border,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color color;
  final Color background;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      shape: StadiumBorder(
        side: BorderSide(
          color: border ?? color.withOpacity(0.18),
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 7),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: AppText.meta,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 圆形图标按钮（头部 36×36）
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 36,
    this.iconSize = 18,
    this.background = AppColors.surface,
    this.color = const Color(0xFF4B5563),
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final Color background;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget button = Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: color),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 小徽标（「08:00 已服」「需登录」这类）
class SoftBadge extends StatelessWidget {
  const SoftBadge({
    super.key,
    required this.text,
    required this.foreground,
    required this.background,
  });

  final String text;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.badge),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppText.tiny,
          fontWeight: FontWeight.w500,
          color: foreground,
        ),
      ),
    );
  }
}

/// 空状态：一屏只有一句话 + 一个动作
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56, color: AppColors.faint),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: AppText.h2,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: AppText.caption,
                height: 1.6,
                color: AppColors.muted,
              ),
            ),
            if (action != null) ...<Widget>[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}

/// 页面顶部导航（返回 + 标题 + 右侧可选动作）
class SimpleNavBar extends StatelessWidget {
  const SimpleNavBar({
    super.key,
    required this.title,
    this.onBack,
    this.trailing,
    this.leadingIcon = Icons.arrow_back_ios_new_rounded,
  });

  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  final IconData leadingIcon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: Icon(leadingIcon, size: 20, color: AppColors.ink),
              padding: const EdgeInsets.only(left: 8, right: 4),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: AppText.h2,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
          ),
          if (trailing != null) trailing!,
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}
