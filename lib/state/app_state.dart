import 'package:flutter/foundation.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../services/app_settings.dart';
import '../services/medication_repository.dart';
import '../services/reminder_scheduler.dart';

/// 全局状态（V1 用 ChangeNotifier，不引第三方状态库）
///
/// 为什么不用 Provider/Riverpod：V1 只有一个数据源（本机数据库）
/// 和一个消费面（三个 Tab 页）。一个 ChangeNotifier + 顶层 AnimatedBuilder
/// 就够了，少一个依赖，也少一层理解成本。
///
/// 所有写操作都遵循同一个顺序：
/// **先写库 → 再重建通知 → 最后 notifyListeners**。
/// 顺序反了会出现「界面已打勾但通知没取消」的不一致。
class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  final MedicationRepository _repo = MedicationRepository.instance;
  final AppSettings settings = AppSettings.instance;

  List<Medication> _meds = const <Medication>[];
  Map<String, IntakeStatus> _status = const <String, IntakeStatus>{};
  bool _loading = true;
  bool _notificationGranted = true;

  bool get loading => _loading;

  /// 通知权限是否拿到；首页顶部用它决定是否显示「提醒可能不响」的提示条
  bool get notificationGranted => _notificationGranted;

  List<Medication> get meds => _meds;

  /// 启动：读设置 + 读数据
  Future<void> bootstrap() async {
    await settings.load();
    await refresh();
  }

  void setNotificationGranted(bool value) {
    if (_notificationGranted == value) return;
    _notificationGranted = value;
    notifyListeners();
  }

  /// 重新拉取「今天 + 近 7 天」的数据
  Future<void> refresh() async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);

    _meds = await _repo.activeMedications();
    _status = await _repo.statusInRange(
      today.subtract(const Duration(days: 6)),
      today.add(const Duration(days: 1)),
    );

    _loading = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 首页派生数据
  // ---------------------------------------------------------------------------

  List<DaySlot> get todaySlots => slotsOf(DateTime.now());

  List<DaySlot> slotsOf(DateTime day) => buildSlots(_meds, day, _status);

  int get todayTotal => todaySlots.length;

  int get todayDone => todaySlots.where((DaySlot s) => s.taken).length;

  int get todayPending => todaySlots
      .where((DaySlot s) => !s.taken && !s.skipped)
      .length;

  /// 0.0 ~ 1.0，进度条用
  double get todayProgress =>
      todayTotal == 0 ? 0 : todayDone / todayTotal;

  /// 下一次要吃的药（已过点未打卡的优先，其次未来的）
  DaySlot? get nextSlot {
    final DateTime now = DateTime.now();
    final List<DaySlot> pending = todaySlots
        .where((DaySlot s) => !s.taken && !s.skipped)
        .toList();
    if (pending.isEmpty) return null;
    return pending.firstWhere(
      (DaySlot s) => s.planned.isAfter(now),
      orElse: () => pending.first,
    );
  }

  /// 某天漏服数（历史页用）
  int missedOf(DateTime day) {
    final DateTime now = DateTime.now();
    return slotsOf(day)
        .where((DaySlot s) => s.overdue(now) && !s.taken && !s.skipped)
        .length;
  }

  // ---------------------------------------------------------------------------
  // 写操作
  // ---------------------------------------------------------------------------

  /// 打钩「已服用」
  Future<void> markTaken(DaySlot slot, {String source = 'manual'}) async {
    await _repo.log(
      medicationId: slot.med.id,
      plannedTime: slot.planned,
      status: IntakeStatus.taken,
      source: source,
    );
    await refresh();
  }

  /// 撤销打钩（打错了）
  Future<void> undo(DaySlot slot) async {
    await _repo.undo(slot.med.id, slot.planned);
    await refresh();
  }

  /// 保存药品（新增或编辑）：写库 → 重建通知 → 刷新界面
  Future<void> saveMedication(Medication med) async {
    await _repo.save(med);
    await ReminderScheduler.instance.resync(await _repo.activeMedications());
    await refresh();
  }

  /// 删除药品，同时清掉它的历史记录
  Future<void> deleteMedication(String id) async {
    await _repo.delete(id);
    await ReminderScheduler.instance.resync(await _repo.activeMedications());
    await refresh();
  }
}
