import 'package:flutter/material.dart';

import '../models/medication.dart';
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

/// 药片状的分段选择器（频次、剂量单位这类「几选一」场景）
///
/// 为什么不用 DropdownButton：下拉要两次点击，且选项会被滚动吞掉；
/// 选项数 ≤ 4 时平铺一眼可见，点一次就改完。
class SegmentedPills<T> extends StatelessWidget {
  const SegmentedPills({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.labelOf,
    this.enabled = true,
  });

  final List<T> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        child: Row(
          children: options.map((T o) {
            final bool active = o == value;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled ? () => onChanged(o) : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? AppColors.bg : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.button - 3),
                    boxShadow: active
                        ? const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x0F131A26),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    labelOf(o),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? AppColors.ink : AppColors.sub,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// 胶囊选择器（可换行的多选一小）
///
/// 修 Bug 关键：**用 Wrap + spacing + runSpacing 让最后一项自动换行**。
/// 上一版用的是横向 Row + 固定宽度，屏幕窄或开了大字号时
/// 第 4 个「30 分钟」会被挤出容器压到前面的选项上。
class ChoiceChips<T> extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.labelOf,
    this.spacing = 8,
    this.runSpacing = 8,
  });

  final List<T> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      children: options.map((T o) {
        final bool active = o == value;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(o),
          child: Container(
            constraints: const BoxConstraints(minWidth: 64, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: active ? AppColors.primarySoft : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.badge),
              border: Border.all(
                color: active ? AppColors.primary.withOpacity(0.28) : AppColors.line,
              ),
            ),
            child: Text(
              labelOf(o),
              style: TextStyle(
                fontSize: AppText.caption,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? AppColors.primary : AppColors.sub,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 带标签的表单行：左标签（固定宽）+ 右内容
///
/// 用它而不是在每个页面各写一遍 Row，是为了让「标签宽度、行高、
/// 分隔线缩进」在药品录入页 / 计划设置页完全一致。
class FormRow extends StatelessWidget {
  const FormRow({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.labelWidth = 74,
  });

  final String label;
  final Widget child;
  final String? hint;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: AppText.caption,
                  color: AppColors.muted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                child,
                if (hint != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    hint!,
                    style: const TextStyle(
                      fontSize: AppText.tiny,
                      height: 1.45,
                      color: AppColors.faint,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态徽标：把「已服药 / 已跳过 / 待确认 / 逾期未确认」的配色收在一处，
/// 保证首页、记录页、家属页三处颜色永远一致。
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.status,
    this.compact = false,
  });

  final IntakeStatus status;
  final bool compact;

  /// 统一的四态配色
  static (Color fg, Color bg) colorsOf(IntakeStatus status) {
    switch (status) {
      case IntakeStatus.taken:
        return (const Color(0xFF067647), AppColors.successSoft);
      case IntakeStatus.skipped:
        return (AppColors.sub, AppColors.surface);
      case IntakeStatus.pending:
        return (AppColors.primary, AppColors.primarySoft);
      case IntakeStatus.overdue:
      case IntakeStatus.missed:
        return (AppColors.warn, AppColors.warnSoft);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color bg) = colorsOf(status);
    return SoftBadge(
      text: compact ? _short(status) : status.label,
      foreground: fg,
      background: bg,
    );
  }

  static String _short(IntakeStatus status) {
    switch (status) {
      case IntakeStatus.taken:
        return '已服';
      case IntakeStatus.skipped:
        return '已跳过';
      case IntakeStatus.pending:
        return '待确认';
      case IntakeStatus.overdue:
      case IntakeStatus.missed:
        return '逾期';
    }
  }
}
