/// 用药频次模型
///
/// V1 只保留三种，覆盖 95% 场景：
/// - [daily]    每日 N 个固定时间点（最常见，也是语音录入的最终落点）
/// - [interval] 每隔 X 小时一次（如抗生素「每 8 小时」）
/// - [once]     仅一次（如术前用药）
///
/// 设计说明：interval 在保存时会被展开成一组具体时间点，
/// 落库后统一按 daily 调度，通知层不必区分两种模型，降低出错面。
enum FrequencyType {
  daily('每天固定时间'),
  interval('每隔几小时'),
  once('仅一次');

  const FrequencyType(this.label);
  final String label;

  static FrequencyType fromName(String? value) {
    return FrequencyType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => FrequencyType.daily,
    );
  }
}

/// 药品（一条用药计划）
class Medication {
  Medication({
    required this.id,
    required this.name,
    required this.dosageValue,
    required this.dosageUnit,
    required this.frequency,
    required this.times,
    this.intervalHours,
    this.note,
    this.startDate,
    this.endDate,
    this.enabled = true,
    this.createdAt,
  });

  final String id;
  final String name;

  /// 每次剂量数值，如 1、0.5、100
  final double dosageValue;

  /// 剂量单位，如 片 / 粒 / ml / mg
  final String dosageUnit;

  final FrequencyType frequency;

  /// 每日提醒时间点，格式 'HH:mm'，按时间升序
  final List<String> times;

  /// 仅 [FrequencyType.interval] 有意义
  final int? intervalHours;

  /// 备注：饭前 / 饭后 / 随餐 / 空腹 / 睡前
  final String? note;

  final DateTime? startDate;
  final DateTime? endDate;
  final bool enabled;
  final DateTime? createdAt;

  /// 给用户看的一句剂量文案：「1 片」「0.5 片」
  String get dosageText {
    final v = dosageValue == dosageValue.roundToDouble()
        ? dosageValue.toInt().toString()
        : dosageValue.toString();
    return '$v $dosageUnit';
  }

  /// 通知正文：「降压药 · 1 片 · 饭后」
  String get notificationBody {
    final parts = <String>[name, dosageText];
    if (note != null && note!.isNotEmpty) parts.add(note!);
    return parts.join(' · ');
  }

  /// 今日剩余需服用的时间点（仅用于首页展示）
  List<String> remainingTimesToday(DateTime now) {
    final hm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return times.where((t) => t.compareTo(hm) >= 0).toList();
  }

  Medication copyWith({
    String? name,
    double? dosageValue,
    String? dosageUnit,
    FrequencyType? frequency,
    List<String>? times,
    int? intervalHours,
    String? note,
    bool? enabled,
  }) {
    return Medication(
      id: id,
      name: name ?? this.name,
      dosageValue: dosageValue ?? this.dosageValue,
      dosageUnit: dosageUnit ?? this.dosageUnit,
      frequency: frequency ?? this.frequency,
      times: times ?? this.times,
      intervalHours: intervalHours ?? this.intervalHours,
      note: note ?? this.note,
      startDate: startDate,
      endDate: endDate,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'dosage_value': dosageValue,
        'dosage_unit': dosageUnit,
        'frequency': frequency.name,
        'times': times.join(','),
        'interval_hours': intervalHours,
        'note': note,
        'start_date': startDate?.toIso8601String(),
        'end_date': endDate?.toIso8601String(),
        'enabled': enabled ? 1 : 0,
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
            .where((e) => e.isNotEmpty)
            .toList(),
        intervalHours: map['interval_hours'] as int?,
        note: map['note'] as String?,
        startDate: map['start_date'] == null
            ? null
            : DateTime.tryParse(map['start_date'] as String),
        endDate: map['end_date'] == null
            ? null
            : DateTime.tryParse(map['end_date'] as String),
        enabled: (map['enabled'] as int? ?? 1) == 1,
        createdAt: map['created_at'] == null
            ? null
            : DateTime.tryParse(map['created_at'] as String),
      );
}

/// 服药记录状态
enum IntakeStatus {
  taken('已服用'),
  snoozed('已延后'),
  skipped('已跳过'),
  missed('漏服');

  const IntakeStatus(this.label);
  final String label;

  static IntakeStatus fromName(String? value) => IntakeStatus.values
      .firstWhere((e) => e.name == value, orElse: () => IntakeStatus.taken);
}

/// 一次服药记录
class DoseLog {
  DoseLog({
    required this.id,
    required this.medicationId,
    required this.plannedTime,
    required this.actionTime,
    required this.status,
    this.snoozeCount = 0,
    this.source = 'manual',
  });

  final String id;
  final String medicationId;
  final DateTime plannedTime;
  final DateTime actionTime;
  final IntakeStatus status;
  final int snoozeCount;

  /// manual=手动/语音录入，notification=通知按钮打卡
  final String source;

  Map<String, Object?> toMap() => {
        'id': id,
        'medication_id': medicationId,
        'planned_time': plannedTime.toIso8601String(),
        'action_time': actionTime.toIso8601String(),
        'status': status.name,
        'snooze_count': snoozeCount,
        'source': source,
      };
}
