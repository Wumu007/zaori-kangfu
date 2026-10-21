import 'medication.dart';

/// 首页/历史页共用的「某一刻该吃的一次药」
///
/// 它把「用药计划（Medication）」和「服药记录（DoseLog）」合到一起：
/// 计划决定「应该吃什么、几点吃」，记录决定「实际吃了没有」。
/// 两者都缺一不可 —— 只有计划会不知道吃没吃，只有记录会不知道漏没漏。
class DaySlot {
  DaySlot({
    required this.med,
    required this.planned,
    this.status,
  });

  final Medication med;

  /// 计划服用时刻（当天日期 + HH:mm）
  final DateTime planned;

  /// null = 还没打卡；其余见 [IntakeStatus]
  final IntakeStatus? status;

  /// 展示用的 HH:mm
  String get hm =>
      '${planned.hour.toString().padLeft(2, '0')}:'
      '${planned.minute.toString().padLeft(2, '0')}';

  bool get taken => status == IntakeStatus.taken;
  bool get skipped => status == IntakeStatus.skipped;
  bool get snoozed => status == IntakeStatus.snoozed;

  /// 已到点但没打卡 —— 首页用橙色提示，历史页算「漏服」
  bool overdue(DateTime now) => !taken && !skipped && planned.isBefore(now);

  /// 行内的第二行文案：「1 片 · 饭后」/「1 片 · 饭后 · 已服用」
  String get subtitle {
    final String base =
        med.note == null || med.note!.isEmpty ? med.dosageText : '${med.dosageText} · ${med.note}';
    if (taken) return '$base · 已服用';
    if (skipped) return '$base · 已跳过';
    return base;
  }
}

/// 记录的唯一键：药品 + 具体到分钟的时刻
///
/// 设计说明：键里必须带日期，否则「昨天 08:00」和「今天 08:00」会互相覆盖，
/// 历史页就会显示成「昨天也吃了」。
String slotKey(String medId, DateTime t) {
  final String d = '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
  final String hm = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  return '$medId|$d $hm';
}

/// 把计划铺成某一天的时间轴
///
/// - 跳过已停用的药
/// - 跳过不在疗程区间内的药（startDate / endDate）
/// - 记录映射里查不到 = 未打卡
List<DaySlot> buildSlots(
  List<Medication> meds,
  DateTime day,
  Map<String, IntakeStatus> status,
) {
  final DateTime dayStart = DateTime(day.year, day.month, day.day);
  final List<DaySlot> out = <DaySlot>[];

  for (final Medication m in meds) {
    if (!m.enabled) continue;

    if (m.startDate != null) {
      final DateTime s =
          DateTime(m.startDate!.year, m.startDate!.month, m.startDate!.day);
      if (dayStart.isBefore(s)) continue;
    }
    if (m.endDate != null) {
      final DateTime e =
          DateTime(m.endDate!.year, m.endDate!.month, m.endDate!.day);
      if (dayStart.isAfter(e)) continue;
    }

    for (final String hm in m.times) {
      final List<String> p = hm.split(':');
      final int hour = int.tryParse(p[0]) ?? 8;
      final int minute =
          int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
      final DateTime planned =
          DateTime(day.year, day.month, day.day, hour, minute);
      out.add(DaySlot(
        med: m,
        planned: planned,
        status: status[slotKey(m.id, planned)],
      ));
    }
  }

  out.sort((DaySlot a, DaySlot b) => a.planned.compareTo(b.planned));
  return out;
}
