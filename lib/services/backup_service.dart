import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import 'medication_repository.dart';

/// 导出结果：存到哪了、写了多少行
///
/// 让 UI 能说清「存到哪个文件、导了多少条」—— 老人点完导出最怕的是
/// 「不知道存哪了」，所以路径必须回传给界面展示。
class ExportResult {
  const ExportResult({
    required this.path,
    required this.rows,
    required this.title,
  });

  final String path;
  final int rows;
  final String title;

  String get fileName => p.basename(path);
}

/// 导入前的体检结果
///
/// 导入是**破坏性**操作（会往库里写东西），所以必须先把「会导致什么后果」
/// 算清楚给用户看，而不是点一下就闷头写。
class ImportPreview {
  const ImportPreview({
    required this.medications,
    required this.logs,
    required this.newMedications,
    required this.duplicateMedications,
    required this.newLogs,
    required this.duplicateLogs,
    required this.exportedAt,
    required this.appVersion,
  });

  /// 备份文件里的药品总数
  final int medications;

  /// 备份文件里的记录总数
  final int logs;

  /// 库里没有、会被新增的药品数
  final int newMedications;

  /// 库里已有同 id、会被跳过的药品数
  final int duplicateMedications;

  /// 库里没有、会被新增的记录数
  final int newLogs;

  /// 库里已有同一条记录、会被跳过的记录数
  final int duplicateLogs;

  final DateTime? exportedAt;
  final String? appVersion;

  bool get nothingToDo => newMedications == 0 && newLogs == 0;

  /// 一句话结论（弹窗正文）
  String get summary {
    if (nothingToDo) {
      return '这份备份里的 ${medications} 种药、${logs} 条记录，本机都已经有了，不需要导入。';
    }
    final StringBuffer b = StringBuffer('备份里有 $medications 种药、$logs 条记录。\n\n');
    b.write('导入后会：\n');
    b.write('· 新增 ${newMedications} 种药品');
    if (duplicateMedications > 0) {
      b.write('（另有 $duplicateMedications 种已存在，会跳过，不覆盖本机数据）');
    }
    b.write('\n· 新增 ${newLogs} 条服药记录');
    if (duplicateLogs > 0) {
      b.write('（另有 $duplicateLogs 条已存在，会跳过）');
    }
    return b.toString();
  }
}

/// 备份文件格式标识 —— 只认自己导出的文件
///
/// 为什么要认格式：这是「换手机恢复数据」用的，不是通用导入。
/// 用户如果拿了个别的 CSV 进来，宁可直接说「这不是本 App 的备份」，
/// 也不要猜字段往库里塞 —— 药名和剂量错了代价太大。
const String kBackupFormat = 'zaori-kangfu-backup';
const int kBackupVersion = 1;

/// 导入/导出（纯本地文件，不联网、不上传）
///
/// 两类产物，用途完全不同，不要混：
/// - **可读导出**（CSV + 纯文本摘要）：给人看的，用 WPS/Excel 能打开、能发给医生。
/// - **备份文件**（.json）：给 App 自己读回来的，字段全、带格式标识。
///
/// CSV 一律带 UTF-8 BOM。不带的话 WPS 和 Excel 在中文 Windows 上会把
/// 中文读成乱码 —— 这是导出功能最常见的「导出来了但打不开看」的原因。
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  // ------------------------------------------------------------ 导出：服药记录

  /// 导出某个日期区间的服药记录为 CSV
  ///
  /// [suggestedName] 由调用方按区间拼好，比如「服药记录_2026-09-01_2026-09-30.csv」
  Future<ExportResult?> exportRecords({
    required DateTime from,
    required DateTime to,
    required String suggestedName,
  }) async {
    final _ExportBundle bundle =
        await _buildRecordTable(from: from, to: to);
    return _saveText(
      suggestedName: suggestedName,
      csv: bundle.csv,
      title: '服药记录',
      rows: bundle.rows,
    );
  }

  /// 导出某个日期区间的记录，同时保存一份给老人看的纯文本摘要
  ///
  /// 两个文件一起出：CSV 给会看表格的人，txt 给只想扫一眼的人。
  /// 用同一套区间参数，保证两份内容对得上。
  ///
  /// 返回 null = 用户取消；返回空列表 = 这段时间没有记录。
  Future<List<ExportResult>?> exportRecordsWithSummary({
    required DateTime from,
    required DateTime to,
    required String baseName,
  }) async {
    final _ExportBundle bundle = await _buildRecordTable(from: from, to: to);
    if (bundle.rows == 0) return <ExportResult>[];

    final List<ExportResult> out = <ExportResult>[];
    final ExportResult? csv = await _saveText(
      suggestedName: '$baseName.csv',
      csv: bundle.csv,
      title: '服药记录表格',
      rows: bundle.rows,
    );
    // 用户在「保存到」界面取消了 → 整体视为取消，别再弹第二个保存框
    if (csv == null) return null;
    out.add(csv);

    final ExportResult? txt = await _saveText(
      suggestedName: '$baseName.txt',
      csv: bundle.summary,
      title: '服药记录摘要',
      rows: bundle.rows,
      appendBom: false,
    );
    if (txt != null) out.add(txt);
    return out;
  }

  /// 导出的药品清单（CSV）
  Future<ExportResult?> exportMedications({
    required String suggestedName,
  }) async {
    final List<Medication> all =
        await MedicationRepository.instance.allMedications();
    final StringBuffer b = StringBuffer()
      ..writeln(<String>[
        '药品名称',
        '单次剂量',
        '剂量单位',
        '服用频次',
        '每天时间点',
        '开始日期',
        '结束日期',
        '是否在提醒',
        '停用时间',
        '备注',
      ].map(_csvCell).join(','));

    for (final Medication m in all) {
      b.writeln(<String>[
        m.name,
        _fmtNum(m.dosageValue),
        m.dosageUnit,
        m.frequency.label,
        m.times.join(' / '),
        _date(m.startDate),
        m.endDate == null ? '长期（持续执行）' : _date(m.endDate),
        m.enabled ? '是' : '否',
        m.stoppedAt == null ? '' : _dateTime(m.stoppedAt!),
        m.note ?? '',
      ].map(_csvCell).join(','));
    }

    return _saveText(
      suggestedName: suggestedName,
      csv: b.toString(),
      title: '药品清单',
      rows: all.length,
    );
  }

  // ------------------------------------------------------------ 导出：备份

  /// 导出完整备份（药品 + 全部记录）
  ///
  /// 用 JSON 而不是 SQLite 文件：跨手机、跨 App 版本都能读，
  /// 而且用户能看懂里面写的是什么（万一要人工抢救数据）。
  Future<ExportResult?> exportBackup({required String suggestedName}) async {
    final Database db = await _openDb();
    final List<Map<String, Object?>> meds =
        await db.query('medications', orderBy: 'created_at ASC');
    final List<Map<String, Object?>> logs =
        await db.query('dose_logs', orderBy: 'planned_time ASC');

    final Map<String, Object?> payload = <String, Object?>{
      'format': kBackupFormat,
      'version': kBackupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'medications': meds,
      'logs': logs,
    };

    return _saveText(
      suggestedName: suggestedName,
      csv: const JsonEncoder.withIndent('  ').convert(payload),
      title: '完整备份',
      rows: meds.length + logs.length,
      appendBom: false,
      ext: 'json',
    );
  }

  // ------------------------------------------------------------ 导入

  /// 让用户挑一个备份文件，解析并算出「会发生什么」，**不写库**
  ///
  /// 返回 null = 用户取消了选择。
  /// 抛 [BackupFormatException] = 文件不是本 App 的备份（由调用方转成人话）。
  ///
  /// 同时把原始文本一起带回来：确认导入时不必让用户再选一次文件。
  Future<({ImportPreview preview, String raw})?> pickAndPreview() async {
    const XTypeGroup group = XTypeGroup(
      label: '早日康复备份文件',
      extensions: <String>['json'],
      mimeTypes: <String>['application/json'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return null;
    final String raw = await file.readAsString();
    return (preview: await previewFromJson(raw), raw: raw);
  }

  /// 解析备份文本并做冲突预演（纯函数，测试友好）
  Future<ImportPreview> previewFromJson(String raw) async {
    final Map<String, Object?> data = _decode(raw);

    final List<Map<String, Object?>> meds = _asRows(data['medications']);
    final List<Map<String, Object?>> logs = _asRows(data['logs']);

    final Database db = await _openDb();
    final Set<String> existingMedIds = <String>{
      for (final Map<String, Object?> r in await db.query(
        'medications',
        columns: <String>['id'],
      ))
        r['id'] as String,
    };
    final Set<String> existingLogKeys = <String>{
      for (final Map<String, Object?> r in await db.query(
        'dose_logs',
        columns: <String>['medication_id', 'planned_time'],
      ))
        slotKey(
          r['medication_id'] as String,
          DateTime.parse(r['planned_time'] as String),
        ),
    };

    int newMeds = 0;
    int dupMeds = 0;
    for (final Map<String, Object?> r in meds) {
      final Object? id = r['id'];
      if (id is! String || id.isEmpty) continue;
      if (existingMedIds.contains(id)) {
        dupMeds++;
      } else {
        newMeds++;
      }
    }

    int newLogs = 0;
    int dupLogs = 0;
    for (final Map<String, Object?> r in logs) {
      final String? medId = r['medication_id'] as String?;
      final DateTime? planned =
          DateTime.tryParse(r['planned_time'] as String? ?? '');
      if (medId == null || medId.isEmpty || planned == null) continue;
      if (existingLogKeys.contains(slotKey(medId, planned))) {
        dupLogs++;
      } else {
        newLogs++;
      }
    }

    return ImportPreview(
      medications: meds.length,
      logs: logs.length,
      newMedications: newMeds,
      duplicateMedications: dupMeds,
      newLogs: newLogs,
      duplicateLogs: dupLogs,
      exportedAt: DateTime.tryParse(data['exportedAt'] as String? ?? ''),
      appVersion: data['version']?.toString(),
    );
  }

  /// 真正写库（调用方必须先让用户确认过 [previewFromJson] 的结果）
  ///
  /// 冲突策略：**只补不覆盖**。
  /// 同 id 的药品、同一时刻的记录一律跳过 —— 用户刚在新手机上录了今天的药，
  /// 不应被三天前的备份盖掉。想覆盖的场景（恢复成备份的样子）这一版不做，
  /// 因为它需要「先清库再导入」，风险高得多。
  Future<({int meds, int logs})> importFromJson(String raw) async {
    final Map<String, Object?> data = _decode(raw);
    final List<Map<String, Object?>> meds = _asRows(data['medications']);
    final List<Map<String, Object?>> logs = _asRows(data['logs']);

    final Database db = await _openDb();
    int medCount = 0;
    int logCount = 0;

    await db.transaction((Transaction txn) async {
      for (final Map<String, Object?> r in meds) {
        final String? id = r['id'] as String?;
        if (id == null || id.isEmpty) continue;
        // 逐条判重而不是靠 ConflictAlgorithm.replace：
        // replace 会把用户在本机改过的剂量悄悄改回备份里的旧值
        final List<Map<String, Object?>> hit = await txn.query(
          'medications',
          columns: <String>['id'],
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        if (hit.isNotEmpty) continue;
        await txn.insert('medications', _normalizeMedRow(r),
            conflictAlgorithm: ConflictAlgorithm.abort);
        medCount++;
      }

      for (final Map<String, Object?> r in logs) {
        final String? medId = r['medication_id'] as String?;
        final DateTime? planned =
            DateTime.tryParse(r['planned_time'] as String? ?? '');
        if (medId == null || medId.isEmpty || planned == null) continue;
        final List<Map<String, Object?>> hit = await txn.query(
          'dose_logs',
          columns: <String>['id'],
          where: 'medication_id = ? AND planned_time >= ? AND planned_time < ?',
          whereArgs: <Object?>[
            medId,
            planned.toIso8601String(),
            planned.add(const Duration(minutes: 1)).toIso8601String(),
          ],
          limit: 1,
        );
        if (hit.isNotEmpty) continue;
        await txn.insert('dose_logs', _normalizeLogRow(r),
            conflictAlgorithm: ConflictAlgorithm.abort);
        logCount++;
      }
    });

    return (meds: medCount, logs: logCount);
  }

  // ------------------------------------------------------------ 内部

  Future<Database> _openDb() async {
    // 复用仓储的同一份数据库（同一个路径、同一个版本），
    // 不另开连接，避免两处各自 upgrade 造成 schema 打架
    return MedicationRepository.instance.database;
  }

  Map<String, Object?> _decode(String raw) {
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      throw const BackupFormatException('这个文件不是 JSON，打不开。');
    }
    if (parsed is! Map<String, Object?>) {
      throw const BackupFormatException('文件内容格式不对。');
    }
    if (parsed['format'] != kBackupFormat) {
      throw const BackupFormatException(
        '这不是「早日康复」的备份文件。\n\n'
        '请用「我的 → 数据存储 → 导出完整备份」生成的文件来导入。',
      );
    }
    final int version = int.tryParse(parsed['version']?.toString() ?? '') ?? 0;
    if (version > kBackupVersion) {
      throw BackupFormatException(
        '这份备份来自更新版本的 App（格式 v$version），当前版本读不了，请先升级 App。',
      );
    }
    return parsed;
  }

  List<Map<String, Object?>> _asRows(Object? raw) {
    if (raw is! List) return <Map<String, Object?>>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => m.map(
              (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
            ))
        .toList();
  }

  /// 备份里的行可能缺新版本才有的列，补齐默认值再写
  Map<String, Object?> _normalizeMedRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'name': r['name'] ?? '',
      'dosage_value': (r['dosage_value'] as num?)?.toDouble() ?? 0,
      'dosage_unit': r['dosage_unit'] ?? '片',
      'frequency': FrequencyType.fromName(r['frequency'] as String?).name,
      'times': r['times'] ?? '',
      'interval_hours': r['interval_hours'],
      'note': r['note'],
      'start_date': r['start_date'],
      'end_date': r['end_date'],
      'enabled': r['enabled'] ?? 1,
      'stopped_at': r['stopped_at'],
      'created_at': r['created_at'] ?? DateTime.now().toIso8601String(),
    };
  }

  Map<String, Object?> _normalizeLogRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
      'medication_id': r['medication_id'],
      'planned_time': r['planned_time'],
      'action_time': r['action_time'] ?? DateTime.now().toIso8601String(),
      // 归一化旧状态名，避免把 snoozed/missed 这类历史值写进新库
      'status': IntakeStatus.fromName(r['status'] as String?).name,
      'snooze_count': r['snooze_count'] ?? 0,
      'snooze_minutes': r['snooze_minutes'] ?? 0,
      'source': r['source'] ?? 'import',
    };
  }

  /// 弹系统「保存到」，让用户自己挑位置
  Future<ExportResult?> _saveText({
    required String suggestedName,
    required String csv,
    required String title,
    required int rows,
    bool appendBom = true,
    String ext = 'csv',
  }) async {
    final FileSaveLocation? loc = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(label: title, extensions: <String>[ext]),
      ],
    );
    if (loc == null) return null; // 用户取消

    final File out = File(loc.path);
    final List<int> bytes = <int>[
      // BOM 只给 CSV：Excel/WPS 靠它认出 UTF-8，否则中文药名全是乱码
      if (appendBom) ...<int>[0xEF, 0xBB, 0xBF],
      ...utf8.encode(csv),
    ];
    await out.writeAsBytes(bytes, flush: true);

    debugPrint('[Backup] 已导出 $title → ${loc.path}（$rows 行）');
    return ExportResult(path: loc.path, rows: rows, title: title);
  }

  /// 把「计划 × 记录」铺成一张可读的表
  Future<_ExportBundle> _buildRecordTable({
    required DateTime from,
    required DateTime to,
  }) async {
    final List<Medication> meds =
        await MedicationRepository.instance.allMedications();
    final Map<String, int> bits = await MedicationRepository.instance
        .statusInRange(from, to.add(const Duration(days: 1)));
    final DateTime now = DateTime.now();

    final StringBuffer csv = StringBuffer()
      ..writeln(<String>[
        '日期',
        '计划时间',
        '药品名称',
        '剂量',
        '状态',
        '是否服用',
        '延后分钟',
        '备注',
      ].map(_csvCell).join(','));

    final StringBuffer txt = StringBuffer();
    int rows = 0;
    int taken = 0;
    int notTaken = 0;

    // 按天遍历，保证「那天没有记录」也能如实写成「逾期未确认」，
    // 而不是干脆不出现 —— 漏服恰恰是最该被看见的
    final DateTime lastDay = DateTime(to.year, to.month, to.day);
    for (DateTime day = DateTime(from.year, from.month, from.day);
        !day.isAfter(lastDay);
        day = day.add(const Duration(days: 1))) {
      final List<DaySlot> slots = buildSlots(meds, day, bits);
      if (slots.isEmpty) continue;

      txt.writeln('${_date(day)}（${_weekday(day)}）');
      for (final DaySlot s in slots) {
        final IntakeStatus st = s.displayStatus(now);
        // 未来的时刻不算结果，跳过，否则导出「本周」会有一堆假逾期
        if (s.planned.isAfter(now)) continue;

        rows++;
        if (st.isTaken) {
          taken++;
        } else {
          notTaken++;
        }
        csv.writeln(<String>[
          _date(day),
          s.hm,
          s.med.name,
          s.med.dosageText,
          st.label,
          st.isTaken ? '已服用' : '未服用',
          s.snoozeMinutes == 0 ? '' : '${s.snoozeMinutes}',
          s.med.note ?? '',
        ].map(_csvCell).join(','));
        txt.writeln('  ${s.hm}  ${s.med.name} ${s.med.dosageText}  '
            '${st.isTaken ? '✓ 已服用' : '✗ 未服用（${st.label}）'}');
      }
      txt.writeln();
    }

    final StringBuffer head = StringBuffer()
      ..writeln('早日康复 · 服药记录摘要')
      ..writeln('统计区间：${_date(from)} 至 ${_date(to)}')
      ..writeln('导出时间：${_dateTime(DateTime.now())}')
      ..writeln()
      ..writeln('这段时间一共 $rows 次计划：已服用 $taken 次，未服用 $notTaken 次。');
    if (rows > 0) {
      final int pct = (taken * 100 / rows).round();
      head.writeln('按时服药比例：$pct%');
    }
    head
      ..writeln()
      ..writeln('说明：跳过、待确认、逾期未确认都算「未服用」。')
      ..writeln('——————————————————————————————')
      ..writeln();

    return _ExportBundle(
      csv: csv.toString(),
      summary: head.toString() + txt.toString(),
      rows: rows,
    );
  }

  /// CSV 单元格转义：含逗号/引号/换行的一律用双引号包起来
  ///
  /// 不转义的话，备注里一个逗号就能把整张表错列 —— 而备注恰恰是
  /// 用户最爱写「饭后吃，别喝茶」这种东西的地方。
  static String _csvCell(String raw) {
    final String v = raw.replaceAll('\r\n', ' ').replaceAll('\n', ' ');
    if (v.contains(',') || v.contains('"')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static String _date(DateTime? d) {
    if (d == null) return '';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  static String _dateTime(DateTime d) =>
      '${_date(d)} ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  static String _weekday(DateTime d) {
    const List<String> names = <String>['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[d.weekday - 1]}';
  }
}

/// 备份文件不合规（不是本 App 的、版本太新、内容损坏）
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _ExportBundle {
  const _ExportBundle({
    required this.csv,
    required this.summary,
    required this.rows,
  });

  final String csv;
  final String summary;
  final int rows;
}
