import 'medication.dart';

/// ============================================================================
/// 「某一刻该吃的一次药」——计划与记录的合体
///
/// 计划（[Medication]）回答「应该吃什么、几点吃」，
/// 记录（DoseLog）回答「实际吃了没有」。
/// 两者都缺一不可：只有计划不知道吃没吃，只有记录不知道漏没漏。
/// ============================================================================
class DaySlot {
  DaySlot({
    required this.med,
    required this.planned,
    this.status,
    this.snoozeMinutes = 0,
  });

  final Medication med;

  /// 计划服用时刻（当天日期 + HH:mm）
  final DateTime planned;

  /// null = 还没到点，也没任何记录
  final IntakeStatus? status;

  /// 已经「稍后提醒」累计了多少分钟（用于文案「已延后 10 分钟」）
  final int snoozeMinutes;

  /// 展示用的 HH:mm
  String get hm =>
      '${planned.hour.toString().padLeft(2, '0')}:'
      '${planned.minute.toString().padLeft(2, '0')}';

  bool get taken => status == IntakeStatus.taken;
  bool get skipped => status == IntakeStatus.skipped;
  bool get snoozed => status == IntakeStatus.pending;

  /// 逾期宽限期：到点后 30 分钟内仍算「待确认」，超过才算「逾期未确认」。
  /// 之所以给宽限：用户可能正在倒水、找药，立刻判「逾期」会让人焦虑，
  /// 而历史统计里 30 分钟内的延迟本来也不影响依从性判断。
  static const Duration grace = Duration(minutes: 30);

  /// 是否已过宽限期（此刻的实时判断，历史日期恒为 true）
  bool isOverdue(DateTime now) => !planned
      .add(grace)
      .isAfter(now);

  /// 聚合后的显示状态——首页/记录页/家属页统一读这里，避免各页各写一套 if
  IntakeStatus displayStatus(DateTime now) {
    final IntakeStatus? s = status;
    if (s != null) {
      // 记录里存了「待确认」，但现在已经逾期：显示为逾期未确认
      if (s == IntakeStatus.pending && isOverdue(now)) return IntakeStatus.overdue;
      return s;
    }
    return isOverdue(now) ? IntakeStatus.overdue : IntakeStatus.pending;
  }

  /// 是否算「未服用」——除了「已服药」以外全部算未服用。
  /// 注：「待确认」在到点前属于「还没到点」，不参与统计，
  /// 所以统计口径用 [countsAsMissed] 而不是直接取反。
  bool get countsAsTaken => displayStatus(planned).isTaken;

  /// 第二行文案：「1 片 · 饭后」/「1 片 · 饭后 · 已服药」
  String get subtitle {
    final String base = med.note == null || med.note!.isEmpty
        ? med.dosageText
        : '${med.dosageText} · ${med.note}';
    final IntakeStatus? s = status;
    if (s == null) return base;
    if (s == IntakeStatus.pending && snoozeMinutes > 0) {
      return '$base · 已延后 $snoozeMinutes 分钟';
    }
    return '$base · ${s.label}';
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

/// 'HH:mm' → 当天该时刻
DateTime atHm(DateTime day, String hm) {
  final List<String> p = hm.split(':');
  final int hour = int.tryParse(p[0]) ?? 8;
  final int minute = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
  return DateTime(day.year, day.month, day.day, hour, minute);
}

/// 把计划铺成某一天的时间轴
///
/// [includeInactive] 为 true 时连已停用的药也铺出来（历史页要看「那天本来该吃什么」），
/// 停用只影响「今天以后还要不要提醒」，不影响「过去发生过什么」。
List<DaySlot> buildSlots(
  List<Medication> meds,
  DateTime day,
  Map<String, int> statusBits,
) {
  final List<DaySlot> out = <DaySlot>[];
  for (final Medication m in meds) {
    out.addAll(buildSlotsOfMed(m, day, statusBits));
  }
  out.sort((DaySlot a, DaySlot b) => a.planned.compareTo(b.planned));
  return out;
}

/// 单个药品在某天的时间轴（编辑页预览、停用前确认都用得到）
List<DaySlot> buildSlotsOfMed(
  Medication m,
  DateTime day,
  Map<String, int> statusBits,
) {
  final List<DaySlot> out = <DaySlot>[];
  if (!m.coversDay(day)) return out;

  // 停用时刻之前的那几次：那天本来该吃，只是后来用户把药停了
  for (final String hm in m.times) {
    final DateTime planned = atHm(day, hm);
    final int? packed = statusBits[slotKey(m.id, planned)];
    final IntakeStatus? st =
        packed == null ? null : IntakeStatus.values[packed & 0xff];
    final int snooze = packed == null ? 0 : (packed >> 8);
    out.add(DaySlot(
      med: m,
      planned: planned,
      status: st,
      snoozeMinutes: snooze,
    ));
  }
  return out;
}

/// 记录的紧凑编码：低 8 位放状态序号，高位放累计延后分钟数。
///
/// 为什么不用对象：一次取 30 天记录时 Map<String, 对象> 会产生几百个小对象，
/// 而界面只读不写，编码成 int 更省内存，也避免误改缓存。
int packStatus(IntakeStatus status, {int snoozeMinutes = 0}) {
  return status.index | (snoozeMinutes.clamp(0, 0xffffff) << 8);
}

IntakeStatus unpackStatus(int packed) => IntakeStatus.values[packed & 0xff];
int unpackSnooze(int packed) => packed >> 8;
