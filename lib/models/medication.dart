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

/// 服药日的重复周期（V1.3 新增）
///
/// 与 [FrequencyType] 的分工：FrequencyType 回答「一天吃几次」，
/// RepeatType 回答「哪些天吃」。两维正交，互不替代。
/// - [daily]   每天（旧行为，默认值，老数据迁移后语义不变）
/// - [weekly]  每周指定星期几，如「每周二、周四」= 每周两次
/// - [monthly] 每月指定几号，如「每月 1、15 日」
enum RepeatType {
  daily('每天'),
  weekly('每周'),
  monthly('每月');

  const RepeatType(this.label);
  final String label;

  /// 兼容旧库：没有 repeat 列的数据一律按 daily
  static RepeatType fromName(String? value) {
    switch (value) {
      case 'weekly':
        return RepeatType.weekly;
      case 'monthly':
        return RepeatType.monthly;
      case 'daily':
      default:
        return RepeatType.daily;
    }
  }
}

/// ISO 星期号 → 中文（1 = 周一 … 7 = 周日），录入页与导出共用
const List<String> kWeekdayNames = <String>[
  '周一', '周二', '周三', '周四', '周五', '周六', '周日',
];

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
    this.repeat = RepeatType.daily,
    List<int>? weekdays,
    List<int>? monthDays,
    this.doseValues,
  })  : weekdays = (weekdays == null || weekdays.isEmpty)
            ? const <int>[DateTime.monday]
            : (weekdays.toList()..sort()),
        monthDays = (monthDays == null || monthDays.isEmpty)
            ? const <int>[1]
            : (monthDays.toList()..sort());

  final String id;
  final String name;

  /// 每次剂量数值（默认剂量），如 1、0.5、100
  final double dosageValue;

  /// 剂量单位，见 [kDosageUnits]
  final String dosageUnit;

  final FrequencyType frequency;

  /// 提醒时间点，格式 'HH:mm'，按时间升序、无重复
  final List<String> times;

  /// 重复周期（V1.3）：每天 / 每周指定日 / 每月指定日
  final RepeatType repeat;

  /// 每周服药的星期号（ISO：1=周一 … 7=周日），仅 [RepeatType.weekly] 有效。
  /// 构造时空列表会归一为 [DateTime.monday]，保证「每周两次」这类语义总有落点。
  final List<int> weekdays;

  /// 每月服药的日期号（1-31），仅 [RepeatType.monthly] 有效。
  /// 大于当月天数的号自动落到当月最后一天（如 31 号在 4 月按 30 号算）。
  final List<int> monthDays;

  /// 每个时间点的独立剂量，与 [times] 按下标对齐；null 或缺位 = 用默认剂量
  /// [dosageValue]。典型场景：早上 1 片、晚上半片。
  final List<double>? doseValues;

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

  /// 某个时间点该吃多少：优先读 [doseValues] 里对应该时间点的独立剂量，
  /// 没配独立剂量时回落到默认 [dosageValue]。
  double doseValueAt(String hm) {
    final List<double>? v = doseValues;
    if (v == null) return dosageValue;
    final int i = times.indexOf(hm);
    if (i < 0 || i >= v.length) return dosageValue;
    final double? d = v[i];
    return d == null || d <= 0 ? dosageValue : d;
  }

  /// 某个时间点的剂量文案（首页/记录页/导出统一走这里）
  String dosageTextOf(String hm) {
    final double v = doseValueAt(hm);
    final String n = v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return '$n $dosageUnit';
  }

  /// 通知正文：「降压药 · 1 片 · 饭后」
  String get notificationBody => '$name · $dosageText';

  /// 频次文案：「每天 08:00」「每周二、周四 2 次」「每月 1、15 日 3 次」
  String get frequencyText {
    switch (repeat) {
      case RepeatType.weekly:
        final String days = weekdays.map((int w) => kWeekdayNames[w - 1]).join('、');
        return '每周$days · ${times.length} 次';
      case RepeatType.monthly:
        final String days = monthDays.join('、');
        return '每月 $days 日 · ${times.length} 次';
      case RepeatType.daily:
        if (frequency == FrequencyType.custom) {
          return '自定义 ${times.length} 个时间';
        }
        if (times.length <= 1) return '每日一次';
        return '每日${_cnNumber(times.length)}次';
    }
  }

  /// 计划文案：「每天 08:00、20:00」「周二、周四 08:00」
  String get scheduleText {
    if (times.isEmpty) return '未设置时间';
    final String t = times.join('、');
    switch (repeat) {
      case RepeatType.weekly:
        return '${weekdays.map((int w) => kWeekdayNames[w - 1]).join('、')} $t';
      case RepeatType.monthly:
        return '每月${monthDays.join('、')}日 $t';
      case RepeatType.daily:
        return '每天 $t';
    }
  }

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

  /// 某一天这条计划是否生效（按重复周期 + 起止日期判定，不看 enabled）
  bool coversDay(DateTime day) {
    final DateTime d = DateTime(day.year, day.month, day.day);
    final DateTime? s = startDate;
    if (s != null && d.isBefore(DateTime(s.year, s.month, s.day))) return false;
    final DateTime? e = endDate;
    if (e != null && d.isAfter(DateTime(e.year, e.month, e.day))) return false;

    // 重复周期判定
    switch (repeat) {
      case RepeatType.daily:
        return true;
      case RepeatType.weekly:
        return weekdays.contains(d.weekday);
      case RepeatType.monthly:
        // 「31 号」这类当月不存在的日期，自动落到当月最后一天，
        // 否则 2 月、4 月会整月都不响，用户以为 App 坏了
        final int lastDay = DateTime(d.year, d.month + 1, 0).day;
        if (d.day == lastDay && monthDays.any((int m) => m > lastDay)) {
          return true;
        }
        return monthDays.contains(d.day);
    }
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
    RepeatType? repeat,
    List<int>? weekdays,
    List<int>? monthDays,
    List<double>? doseValues,
    bool clearDoseValues = false,
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
      repeat: repeat ?? this.repeat,
      weekdays: weekdays ?? this.weekdays,
      monthDays: monthDays ?? this.monthDays,
      doseValues: clearDoseValues ? null : (doseValues ?? this.doseValues),
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
        'repeat': repeat.name,
        'weekdays': repeat == RepeatType.weekly ? weekdays.join(',') : null,
        'month_days': repeat == RepeatType.monthly ? monthDays.join(',') : null,
        'dose_values': doseValues?.map(_fmtNum).join(','),
      };

  static Medication fromMap(Map<String, Object?> map) {
    final RepeatType repeat = RepeatType.fromName(map['repeat'] as String?);
    return Medication(
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
      repeat: repeat,
      weekdays: repeat == RepeatType.weekly
          ? _parseIntList(map['weekdays'] as String?)
          : null,
      monthDays: repeat == RepeatType.monthly
          ? _parseIntList(map['month_days'] as String?)
          : null,
      doseValues: _parseDoubleList(map['dose_values'] as String?),
    );
  }

  static List<int> _parseIntList(String? raw) => (raw ?? '')
      .split(',')
      .map((String e) => int.tryParse(e.trim()) ?? 0)
      .where((int e) => e > 0)
      .toList();

  static List<double>? _parseDoubleList(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final List<double> out = raw
        .split(',')
        .map((String e) => double.tryParse(e.trim()))
        .whereType<double>()
        .where((double v) => v > 0)
        .toList();
    return out.isEmpty ? null : out;
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

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
