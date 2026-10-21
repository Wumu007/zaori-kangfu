import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';

/// 用药计划 + 服药记录的本地存储（V1 纯本地，不联网、不登录）
class MedicationRepository {
  MedicationRepository._();
  static final MedicationRepository instance = MedicationRepository._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'med_reminder.db'),
      version: 1,
      onCreate: (db, version) async {
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
            source TEXT NOT NULL DEFAULT 'manual'
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_log_med ON dose_logs(medication_id, planned_time)');
      },
    );
    return _db!;
  }

  Future<List<Medication>> activeMedications() async {
    final db = await _database;
    final rows = await db.query('medications',
        where: 'enabled = 1', orderBy: 'created_at ASC');
    return rows.map(Medication.fromMap).toList();
  }

  Future<void> save(Medication med) async {
    final db = await _database;
    await db.insert('medications', med.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete('medications', where: 'id = ?', whereArgs: [id]);
    await db.delete('dose_logs', where: 'medication_id = ?', whereArgs: [id]);
  }

  /// 打钩：记录「已服用 / 已跳过 / 已延后」
  Future<void> log({
    required String medicationId,
    required DateTime plannedTime,
    required IntakeStatus status,
    String source = 'manual',
    int snoozeCount = 0,
  }) async {
    final db = await _database;
    // 只清理「同一分钟」的旧记录，避免重复打卡；不影响当天其他时间点
    final slotStart = plannedTime;
    final slotEnd = plannedTime.add(const Duration(minutes: 1));
    await db.delete(
      'dose_logs',
      where: 'medication_id = ? AND planned_time >= ? AND planned_time < ?',
      whereArgs: [
        medicationId,
        slotStart.toIso8601String(),
        slotEnd.toIso8601String(),
      ],
    );
    await db.insert('dose_logs', {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'medication_id': medicationId,
      'planned_time': plannedTime.toIso8601String(),
      'action_time': DateTime.now().toIso8601String(),
      'status': status.name,
      'snooze_count': snoozeCount,
      'source': source,
    });
  }

  /// 全部药品（含已停用）—— 历史页要回看老计划，停用的不能丢
  Future<List<Medication>> allMedications() async {
    final db = await _database;
    final rows = await db.query('medications', orderBy: 'created_at ASC');
    return rows.map(Medication.fromMap).toList();
  }

  /// 一段时间的服药记录
  ///
  /// 返回 Map 的 key 用 [slotKey]（药名 id + 精确到分钟的日期时间），
  /// 这样首页（今天）和历史页（近 7 天）能共用同一套拼装逻辑。
  Future<Map<String, IntakeStatus>> statusInRange(
    DateTime from,
    DateTime to,
  ) async {
    final db = await _database;
    final rows = await db.query(
      'dose_logs',
      where: 'planned_time >= ? AND planned_time < ?',
      whereArgs: [from.toIso8601String(), to.toIso8601String()],
    );
    final map = <String, IntakeStatus>{};
    for (final r in rows) {
      final t = DateTime.parse(r['planned_time'] as String);
      map[slotKey(r['medication_id'] as String, t)] =
          IntakeStatus.fromName(r['status'] as String?);
    }
    return map;
  }

  /// 撤销打钩（误触保护）：只撤销该时间点
  Future<void> undo(String medicationId, DateTime plannedTime) async {
    final db = await _database;
    await db.delete(
      'dose_logs',
      where: 'medication_id = ? AND planned_time >= ? AND planned_time < ?',
      whereArgs: [
        medicationId,
        plannedTime.toIso8601String(),
        plannedTime.add(const Duration(minutes: 1)).toIso8601String(),
      ],
    );
  }
}
