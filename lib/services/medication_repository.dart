import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';

/// 用量统计（某个日期区间的依从率）
class AdherenceStat {
  AdherenceStat({
    required this.total,
    required this.taken,
    required this.skipped,
    required this.pending,
    required this.overdue,
  });

  /// 只统计「已经有结论」的次数：已服药 + 已跳过 + 逾期未确认。
  /// 「待确认」是还没到点或还在宽限期内的，不能算进分母，
  /// 否则早上一起床看到 0/3 会以为漏服了。
  final int total;
  final int taken;
  final int skipped;
  final int pending;
  final int overdue;

  /// 是否实际服用的次数
  int get notTaken => skipped + overdue;

  /// 依从率 0~1（没有可统计次数时返回 1，避免首页显示 0%）
  double get rate => total == 0 ? 1 : taken / total;
}

/// 用药计划 + 服药记录的本地存储（纯本地，不联网、不登录）
///
/// 版本历史：
/// v1 —— 首次发布，medications + dose_logs 两张表
/// v2 —— 用药计划加 stopped_at（停用时刻），新增 custom_times 语义等价于 times；
///        dose_logs 增加 snooze_minutes（累计延后时长）。
///        迁移用 ALTER TABLE 增量加列，不重建表 —— 用户装的是 v1，
///        升级后历史记录必须原样还在。
class MedicationRepository {
  MedicationRepository._();
  static final MedicationRepository instance = MedicationRepository._();

  static const int _dbVersion = 2;
  Database? _db;

  /// 给备份/导入用的原始连接
  ///
  /// 为什么公开：导入导出要在一个事务里跨两张表读写，用它自己的
  /// [log]、[save] 会拆成多次独立写入，中途失败就留下半份数据。
  /// 只读地用（query/insert）由 [BackupService] 负责，不要在这里加业务逻辑。
  Future<Database> get database => _database;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final String dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'med_reminder.db'),
      version: _dbVersion,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE medications(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            dosage_value REAL NOT NULL,
            dosage_unit TEXT NOT NULL,
            frequency TEXT NOT NULL,
            times TEXT NOT NULL,
            interval_hours INTEGER,
            note TEXT,
            start_date TEXT,
            end_date TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            stopped_at TEXT,
            created_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE dose_logs(
            id TEXT PRIMARY KEY,
            medication_id TEXT NOT NULL,
            planned_time TEXT NOT NULL,
            action_time TEXT NOT NULL,
            status TEXT NOT NULL,
            snooze_count INTEGER NOT NULL DEFAULT 0,
            snooze_minutes INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'manual'
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_log_med ON dose_logs(medication_id, planned_time)');
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await _addColumnIfMissing(
              db, 'medications', 'stopped_at', 'TEXT');
          await _addColumnIfMissing(
              db, 'dose_logs', 'snooze_minutes', 'INTEGER NOT NULL DEFAULT 0');
          // V1 的「已延后(snoozed)」语义就是现在的「待确认(pending)」，
          // 顺手归一化，避免新代码里到处判兼容值
          await db.update(
            'dose_logs',
            <String, Object?>{'status': IntakeStatus.pending.name},
            where: 'status = ?',
            whereArgs: <Object?>['snoozed'],
          );
        }
      },
    );
    return _db!;
  }

  /// 列已存在时 ALTER 会抛异常，这里先查表结构再决定是否加
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    final List<Map<String, Object?>> info =
        await db.rawQuery('PRAGMA table_info($table)');
    final bool exists = info.any((Map<String, Object?> r) => r['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  // ------------------------------------------------------------------ 药品

  /// 仍在提醒中的药（已停用、已过有效期的不出现在提醒列表里）
  Future<List<Medication>> activeMedications() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'medications',
      where: 'enabled = 1',
      orderBy: 'created_at ASC',
    );
    return _sorted(rows.map(Medication.fromMap).toList());
  }

  /// 全部药品（含已停用）—— 历史页要回看老计划，停用的不能丢
  Future<List<Medication>> allMedications() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows =
        await db.query('medications', orderBy: 'created_at ASC');
    return _sorted(rows.map(Medication.fromMap).toList());
  }

  /// 按「每天第一次服药的时间」排序，和用户脑海里的顺序一致
  static List<Medication> _sorted(List<Medication> list) {
    int key(Medication m) {
      if (m.times.isEmpty) return 24 * 60;
      final List<String> s = List<String>.from(m.times)..sort();
      final List<String> p = s.first.split(':');
      return (int.tryParse(p[0]) ?? 8) * 60 + (int.tryParse(p[1]) ?? 0);
    }

    list.sort((Medication a, Medication b) => key(a).compareTo(key(b)));
    return list;
  }

  Future<void> save(Medication med) async {
    final Database db = await _database;
    await db.insert('medications', med.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 删除药品，同时清掉它的历史记录（界面上会二次确认）
  Future<void> delete(String id) async {
    final Database db = await _database;
    await db.delete('medications', where: 'id = ?', whereArgs: <Object?>[id]);
    await db.delete('dose_logs',
        where: 'medication_id = ?', whereArgs: <Object?>[id]);
  }

  // ------------------------------------------------------------------ 记录

  /// 写一条服药记录（同一时间点已有记录则替换）
  ///
  /// [snoozeMinutes] 是**累计**延后时长，不是本次增加量 ——
  /// 因为界面上要显示「已延后 10 分钟」，累加逻辑放在调用方更清晰。
  Future<void> log({
    required String medicationId,
    required DateTime plannedTime,
    required IntakeStatus status,
    String source = 'manual',
    int snoozeCount = 0,
    int snoozeMinutes = 0,
  }) async {
    final Database db = await _database;
    await _deleteSlot(db, medicationId, plannedTime);
    await db.insert('dose_logs', <String, Object?>{
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'medication_id': medicationId,
      'planned_time': plannedTime.toIso8601String(),
      'action_time': DateTime.now().toIso8601String(),
      'status': status.name,
      'snooze_count': snoozeCount,
      'snooze_minutes': snoozeMinutes,
      'source': source,
    });
  }

  /// 只清理「同一分钟」的旧记录，不影响当天其他时间点
  Future<void> _deleteSlot(
    Database db,
    String medicationId,
    DateTime plannedTime,
  ) async {
    await db.delete(
      'dose_logs',
      where: 'medication_id = ? AND planned_time >= ? AND planned_time < ?',
      whereArgs: <Object?>[
        medicationId,
        plannedTime.toIso8601String(),
        plannedTime.add(const Duration(minutes: 1)).toIso8601String(),
      ],
    );
  }

  /// 一条记录（含累计延后分钟数）；不存在返回 null
  Future<({IntakeStatus status, int snoozeMinutes})?> logOf(
    String medicationId,
    DateTime plannedTime,
  ) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'dose_logs',
      where: 'medication_id = ? AND planned_time >= ? AND planned_time < ?',
      whereArgs: <Object?>[
        medicationId,
        plannedTime.toIso8601String(),
        plannedTime.add(const Duration(minutes: 1)).toIso8601String(),
      ],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final Map<String, Object?> r = rows.first;
    return (
      status: IntakeStatus.fromName(r['status'] as String?),
      snoozeMinutes: (r['snooze_minutes'] as int?) ?? 0,
    );
  }

  /// 一段时间的服药记录，返回 [slotKey] → 紧凑编码（见 [packStatus]）
  ///
  /// 用 int 而不是对象：一个月约 90 条记录，编码后是一个轻量 Map，
  /// 界面每帧读它做派生数据时不会产生 GC 压力。
  Future<Map<String, int>> statusInRange(DateTime from, DateTime to) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'dose_logs',
      where: 'planned_time >= ? AND planned_time < ?',
      whereArgs: <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final Map<String, int> map = <String, int>{};
    for (final Map<String, Object?> r in rows) {
      final DateTime t = DateTime.parse(r['planned_time'] as String);
      map[slotKey(r['medication_id'] as String, t)] = packStatus(
        IntakeStatus.fromName(r['status'] as String?),
        snoozeMinutes: (r['snooze_minutes'] as int?) ?? 0,
      );
    }
    return map;
  }

  /// 某个药最近一次服药时间（药品列表里显示「上次服用」）
  Future<DateTime?> lastTakenAt(String medicationId) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'dose_logs',
      columns: <String>['planned_time'],
      where: 'medication_id = ? AND status = ?',
      whereArgs: <Object?>[medicationId, IntakeStatus.taken.name],
      orderBy: 'planned_time DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DateTime.tryParse(rows.first['planned_time'] as String);
  }

  /// 撤销打钩（误触保护）：只撤销该时间点
  Future<void> undo(String medicationId, DateTime plannedTime) async {
    final Database db = await _database;
    await _deleteSlot(db, medicationId, plannedTime);
  }
}
