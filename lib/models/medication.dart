/// ============================================================================
/// 用药计划与服药记录的数据模型
///
/// V2 相比 V1 的三处结构变化（都来自真实试用反馈）：
/// 1. 频次从「枚举 + 一堆时间点」升级为三种明确语义：
///    [FrequencyType.once]   每日一次  —— 只有一个时间点
///    [FrequencyType.multi]  每日多次  —— 一天里多个固定时间点
///    [FrequencyType.custom] 自定义    —— 想几点就几点，任意时间点集合
///    三者在存储上都是 `times: List<String>`，区别只在录入与文案。
///    这样调度层只认时间点，不需要为三种频次写三套逻辑。
/// 2. 计划有了完整的**有效期**：开始日期 + 结束日期，
///    结束日期为空 = 长期用药（持续执行，直到用户手动停用）。
/// 3. 停用不再只是「不提醒」，而是记录**停用时刻**（[stoppedAt]），
///    这样历史页能精确回答「停用那天上午的药到底该不该出现」。
/// ============================================================================
library;

/// 用药频次
enum FrequencyType {
  once('每日一次'),
  multi('每日多次'),
  custom('自定义时间');

  const FrequencyType(this.label);
  final String label;

  /// 兼容旧库里的 daily / interval / once 三种取值
  static FrequencyType fromName(String? value) {
    switch (value) {
      case 'once':
        return FrequencyType.once;
      case 'custom':
        return FrequencyType.custom;
      case 'interval':
        // V1 的「每隔几小时」在保存时已展开成具体时间点，语义等价于自定义
        return FrequencyType.custom;
      case 'multi':
      case 'daily':
      default:
        return FrequencyType.multi;
    }
  }

  /// 按时间点数量反推频次（用于语音录入后的自动判定）
  static FrequencyType infer(int timeCount) =>
      timeCount <= 1 ? FrequencyType.once : FrequencyType.multi;
}

/// 剂量单位候选（录入页与语音解析共用一份，避免两处不一致）
const List<String> kDosageUnits = <String>[
  '片',
  '粒',
  '袋',
  'ml',
  'mg',
  'g',
  'μg',
  '滴',
  '喷',
  '支',
  '单位',
];

/// 一条用药计划（一个药）
class Medication {
  Medication({
    required this.id,
    required this.name,
    required this.dosageValue,
    required this.dosageUnit,
    required this.frequency,
    required this.times,
    this.note,
    this.startDate,
    this.endDate,
    this.enabled = true,
    this.stoppedAt,
    this.createdAt,
  });

  final String id;
  final String name;

  /// 每次剂量数值，如 1、0.5、100
  final double dosageValue;

  /// 剂量单位，见 [kDosageUnits]
  final String dosageUnit;

  final FrequencyType frequency;

  /// 每天提醒时间点，格式 'HH:mm'，按时间升序、无重复
  final List<String> times;

  /// 备注：饭前 / 饭后 / 随餐 / 空腹 / 睡前
  final String? note;

  /// 计划开始日期（含当天）。null = 不限起始
  final DateTime? startDate;

  /// 计划结束日期（含当天）。null = 长期，持续执行直到手动停用
  final DateTime? endDate;

  /// 是否仍在提醒中。false = 用户手动停用（历史记录保留）
  final bool enabled;

  /// 停用时刻。历史页用它判断「停用前的计划是否该显示」
  final DateTime? stoppedAt;

  final DateTime? createdAt;

  // ------------------------------------------------------------------ 展示文案

  /// 给用户看的一句剂量文案：「1 片」「0.5 片」
  String get dosageText {
    final String v = dosageValue == dosageValue.roundToDouble()
        ? dosageValue.toInt().toString()
        : dosageValue.toString();
    return '$v $dosageUnit';
  }

  /// 通知正文：「降压药 · 1 片 · 饭后」
  String get notificationBody => '$name · $dosageText';

  /// 频次文案：「每日一次」「每日两次」「自定义 3 个时间」
  String get frequencyText {
    if (frequency == FrequencyType.custom) {
      return '自定义 ${times.length} 个时间';
    }
    if (times.length <= 1) return '每日一次';
    return '每日${_cnNumber(times.length)}次';
  }

  /// 计划文案：「每天 08:00」/「每天 08:00、20:00」
  String get scheduleText =>
      times.isEmpty ? '未设置时间' : '每天 ${times.join('、')}';

  /// 有效期文案：「长期」「2026-10-22 起」「2026-10-22 ~ 2026-12-31」
  String get periodText {
    final String? s = startDate == null ? null : _fmtDate(startDate!);
    final String? e = endDate == null ? null : _fmtDate(endDate!);
    if (s == null && e == null) return '长期（持续执行）';
    if (e == null) return '$s 起 · 长期';
    if (s == null) return '至 $e';
    return '$s ~ $e';
  }

  /// 是否属于「长期用药」
  bool get isOngoing => endDate == null;

  bool get hasEnded {
    final DateTime? e = endDate;
    if (e == null) return false;
    final DateTime today = DateTime.now();
    return DateTime(e.year, e.month, e.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  // ---------------------------------------------------------------- 日期判定

  /// 某一天这条计划是否生效（按起止日期判定，不看 enabled）
  bool coversDay(DateTime day) {
    final DateTime d = DateTime(day.year, day.month, day.day);
    final DateTime? s = startDate;
    if (s != null && d.isBefore(DateTime(s.year, s.month, s.day))) return false;
    final DateTime? e = endDate;
    if (e != null && d.isAfter(DateTime(e.year, e.month, e.day))) return false;
    return true;
  }

  /// 某一天是否**还会**产生提醒：生效 + 未停用 + 未过期
  bool shouldRemindOn(DateTime day) => enabled && coversDay(day);

  // ---------------------------------------------------------------- 序列化

  Medication copyWith({
    String? name,
    double? dosageValue,
    String? dosageUnit,
    FrequencyType? frequency,
    List<String>? times,
    String? note,
    DateTime? startDate,
    DateTime? endDate,
    bool? enabled,
    DateTime? stoppedAt,
    bool clearEndDate = false,
    bool clearStoppedAt = false,
  }) {
    return Medication(
      id: id,
      name: name ?? this.name,
      dosageValue: dosageValue ?? this.dosageValue,
      dosageUnit: dosageUnit ?? this.dosageUnit,
      frequency: frequency ?? this.frequency,
      times: times ?? this.times,
      note: note ?? this.note,
      startDate: startDate ?? this.startDate,
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      enabled: enabled ?? this.enabled,
      stoppedAt: clearStoppedAt ? null : (stoppedAt ?? this.stoppedAt),
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'name': name,
        'dosage_value': dosageValue,
        'dosage_unit': dosageUnit,
        'frequency': frequency.name,
        'times': times.join(','),
        'note': note,
        'start_date': startDate?.toIso8601String(),
        'end_date': endDate?.toIso8601String(),
        'enabled': enabled ? 1 : 0,
        'stopped_at': stoppedAt?.toIso8601String(),
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  static Medication fromMap(Map<String, Object?> map) => Medication(
        id: map['id'] as String,
        name: map['name'] as String,
        dosageValue: (map['dosage_value'] as num).toDouble(),
        dosageUnit: map['dosage_unit'] as String,
        frequency: FrequencyType.fromName(map['frequency'] as String?),
        times: (map['times'] as String? ?? '')
            .split(',')
            .where((String e) => e.isNotEmpty)
            .toList()
          ..sort(),
        note: map['note'] as String?,
        startDate: _parseDate(map['start_date']),
        endDate: _parseDate(map['end_date']),
        enabled: (map['enabled'] as int? ?? 1) == 1,
        stoppedAt: _parseDate(map['stopped_at']),
        createdAt: _parseDate(map['created_at']),
      );

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _cnNumber(int n) {
    const List<String> table = <String>['零', '一', '二', '三', '四', '五', '六'];
    if (n >= 0 && n < table.length) return table[n];
    return n.toString();
  }
}

/// 一次服药的状态
///
/// 四态语义（必须严格区分，因为「是否实际服用」是按这个判定的）：
/// - [taken]    已服药     —— 唯一算「已服用」的状态
/// - [skipped]  已跳过     —— 用户主动放弃这一次，算未服用
/// - [pending]  待确认     —— 已到点，用户点了「稍后提醒」，还没吃，算未服用
/// - [overdue]  逾期未确认 —— 到点后超过宽限期仍无反馈，系统判定，算未服用
///
/// [missed] 是 V1 的旧值，仅为兼容历史数据保留，读取时归一化为 [overdue]。
enum IntakeStatus {
  taken('已服药'),
  skipped('已跳过'),
  pending('待确认'),
  overdue('逾期未确认'),
  missed('逾期未确认');

  const IntakeStatus(this.label);
  final String label;

  /// 是否算「实际服用」——全项目只认这一个判定
  bool get isTaken => this == IntakeStatus.taken;

  /// 是否已经有用户反馈（已服药 / 已跳过 / 待确认）
  /// 逾期未确认是系统自动判定，不算用户反馈
  bool get hasUserFeedback =>
      this == IntakeStatus.taken ||
      this == IntakeStatus.skipped ||
      this == IntakeStatus.pending;

  static IntakeStatus fromName(String? value) {
    switch (value) {
      case 'taken':
        return IntakeStatus.taken;
      case 'skipped':
        return IntakeStatus.skipped;
      case 'pending':
      case 'snoozed': // V1 的「已延后」= 现在的「待确认」
        return IntakeStatus.pending;
      case 'overdue':
      case 'missed':
        return IntakeStatus.overdue;
      default:
        return IntakeStatus.pending;
    }
  }
}
