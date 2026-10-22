import 'package:flutter/foundation.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../services/app_settings.dart';
import '../services/medication_repository.dart';
import '../services/reminder_scheduler.dart';

export '../services/medication_repository.dart' show AdherenceStat;


/// 全局状态（用 ChangeNotifier，不引第三方状态库）
///
/// 为什么不用 Provider/Riverpod：整个 App 只有一个数据源（本机数据库）
/// 和几个消费面（Tab 页 + 二级页）。一个 ChangeNotifier + AnimatedBuilder
/// 就够了，少一个依赖，也少一层理解成本。
///
/// 所有写操作都遵循同一个顺序：
/// **先写库 → 再重排/取消通知 → 最后 notifyListeners**。
/// 顺序反了会出现「界面已打勾但通知还在响」的不一致。
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  final MedicationRepository _repo = MedicationRepository.instance;
  final AppSettings settings = AppSettings.instance;

  /// 全部药品（含已停用的排在后段），药品管理页直接读这个
  List<Medication> _allMeds = const <Medication>[];
  Map<String, int> _statusBits = const <String, int>{};
  bool _loading = true;
  bool _notificationGranted = true;

  bool get loading => _loading;
  bool get notificationGranted => _notificationGranted;

  /// 仍在提醒中的药（首页/家属页用）
  List<Medication> get meds =>
      _allMeds.where((Medication m) => m.enabled).toList();

  /// 含已停用的全部药（药品管理页用）
  List<Medication> get allMeds => _allMeds;

  Future<void> bootstrap() async {
    await settings.load();
    await refresh();
  }

  void setNotificationGranted(bool value) {
    if (_notificationGranted == value) return;
    _notificationGranted = value;
    notifyListeners();
  }

  /// 重新拉取数据：往前 30 天（历史页可以翻）、往后 30 天（今天清单与未来预览）
  Future<void> refresh() async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);

    _allMeds = await _repo.allMedications();
    _statusBits = await _repo.statusInRange(
      today.subtract(const Duration(days: 30)),
      today.add(const Duration(days: 31)),
    );

    _loading = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 派生数据（首页）
  // ---------------------------------------------------------------------------

  List<DaySlot> get todaySlots => slotsOf(DateTime.now());

  /// 某天的全部计划（含已停用药当天之前的安排）
  List<DaySlot> slotsOf(DateTime day) => buildSlots(_allMeds, day, _statusBits);

  /// 某天的计划但**只包含仍在提醒中的药**（家属页、统计用）
  List<DaySlot> activeSlotsOf(DateTime day) => buildSlots(
        _allMeds.where((Medication m) => m.enabled).toList(),
        day,
        _statusBits,
      );

  int get todayTotal => todaySlots.length;

  int get todayDone => todaySlots.where((DaySlot s) => s.taken).length;

  /// 今天还没做完的次数（到点未点、未到点、未反馈都算）
  int get todayPending => todaySlots.where((DaySlot s) => !s.taken).length;

  double get todayProgress => todayTotal == 0 ? 0 : todayDone / todayTotal;

  /// 下一次要吃的药（已过点未打卡的优先，其次未来的）
  DaySlot? get nextSlot {
    final DateTime now = DateTime.now();
    final List<DaySlot> pending =
        todaySlots.where((DaySlot s) => !s.taken && !s.skipped).toList();
    if (pending.isEmpty) return null;
    return pending.firstWhere(
      (DaySlot s) => s.planned.isAfter(now),
      orElse: () => pending.first,
    );
  }

  /// 某天的统计（依从率口径见 [AdherenceStat]）
  AdherenceStat statOf(DateTime day) {
    final DateTime now = DateTime.now();
    final List<DaySlot> slots = slotsOf(day);
    int taken = 0, skipped = 0, pending = 0, overdue = 0;
    for (final DaySlot s in slots) {
      switch (s.displayStatus(now)) {
        case IntakeStatus.taken:
          taken++;
          break;
        case IntakeStatus.skipped:
          skipped++;
          break;
        case IntakeStatus.overdue:
          overdue++;
          break;
        case IntakeStatus.pending:
        case IntakeStatus.missed:
          // 未到点、还在宽限期内、或用户点了稍后提醒
          pending++;
          break;
      }
    }
    return AdherenceStat(
      total: taken + skipped + overdue,
      taken: taken,
      skipped: skipped,
      pending: pending,
      overdue: overdue,
    );
  }

  /// 某天漏服数（历史页日历条用）
  int missedOf(DateTime day) => statOf(day).notTaken;

  /// 某天是否已经没有任何未反馈的计划（全服完 或 全都跳过）
  bool isDaySettled(DateTime day) => statOf(day).pending == 0;

  // ---------------------------------------------------------------------------
  // 写操作：服药反馈
  // ---------------------------------------------------------------------------

  /// 记一笔服药反馈（已服药 / 已跳过 / 稍后提醒）
  Future<void> logSlot(
    DaySlot slot,
    IntakeStatus status, {
    String source = 'manual',
    int snoozeMinutes = 0,
    int snoozeCount = 0,
  }) async {
    await _repo.log(
      medicationId: slot.med.id,
      plannedTime: slot.planned,
      status: status,
      source: source,
      snoozeMinutes: snoozeMinutes,
      snoozeCount: snoozeCount,
    );
    // 已经在 App 里处理过这一顿了，对应通知就不该再响
    await ReminderScheduler.instance.cancelSlot(slot.med.id, slot.planned);
    await refresh();
  }

  Future<void> markTaken(DaySlot slot, {String source = 'manual'}) =>
      logSlot(slot, IntakeStatus.taken, source: source);

  Future<void> markSkipped(DaySlot slot, {String source = 'manual'}) =>
      logSlot(slot, IntakeStatus.skipped, source: source);

  /// 「稍后提醒」：记「待确认」+ 累计延后时长 + 排一条稍后的通知
  Future<void> snoozeSlot(DaySlot slot, {String source = 'manual'}) async {
    final int minutes = settings.snoozeMinutes;
    final int total = slot.snoozeMinutes + minutes;

    await _repo.log(
      medicationId: slot.med.id,
      plannedTime: slot.planned,
      status: IntakeStatus.pending,
      source: source,
      snoozeMinutes: total,
      snoozeCount: 1,
    );
    await ReminderScheduler.instance.snooze(
      medicationId: slot.med.id,
      planned: slot.planned,
      title: '该吃药了',
      body: slot.med.notificationBody,
      name: slot.med.name,
      minutes: minutes,
    );
    await refresh();
  }

  /// 撤销（打错了）
  Future<void> undo(DaySlot slot) async {
    await _repo.undo(slot.med.id, slot.planned);
    await refresh();
  }

  // ---------------------------------------------------------------------------
  // 写操作：药品管理
  // ---------------------------------------------------------------------------

  /// 保存药品（新增或编辑）：写库 → 重建通知 → 刷新界面
  Future<void> saveMedication(Medication med) async {
    await _repo.save(med);
    await ReminderScheduler.instance.resync(await _repo.activeMedications());
    await refresh();
  }

  /// 停用：不再提醒，但历史记录全部保留
  Future<void> stopMedication(Medication med) async {
    await _repo.save(med.copyWith(enabled: false, stoppedAt: DateTime.now()));
    await ReminderScheduler.instance.resync(await _repo.activeMedications());
    await refresh();
  }

  /// 重新启用（用户后悔停用了）
  Future<void> resumeMedication(Medication med) async {
    await _repo.save(med.copyWith(
      enabled: true,
      clearStoppedAt: true,
      // 恢复时把结束日期清空，否则可能一起用就已经过期，
      // 用户会以为「点了恢复但没反应」
      clearEndDate: med.hasEnded,
    ));
    await ReminderScheduler.instance.resync(await _repo.activeMedications());
    await refresh();
  }

  /// 删除药品，同时清掉它的历史记录
  Future<void> deleteMedication(Medication med) async {
    await ReminderScheduler.instance.cancelMedication(med);
    await _repo.delete(med.id);
    await ReminderScheduler.instance.resync(await _repo.activeMedications());
    await refresh();
  }
}
