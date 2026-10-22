import 'package:flutter_test/flutter_test.dart';
import 'package:med_reminder/models/day_slot.dart';
import 'package:med_reminder/models/medication.dart';
import 'package:med_reminder/services/medication_nlu.dart';

/// 语音解析的回归测试
/// 跑法：flutter test test/medication_nlu_test.dart
///
/// 这些用例都来自「老人真实会怎么说」，改动解析规则前先确保全绿。
void main() {
  group('药名 + 剂量 + 频次 完整句', () {
    test('每天两次 早晚各一片 饭后', () {
      final d = MedicationNlu.parse('二甲双胍 每天两次 早晚各一片 饭后吃');
      expect(d.name, '二甲双胍');
      expect(d.dosageValue, 1);
      expect(d.dosageUnit, '片');
      expect(d.times, ['08:00', '20:00']);
      expect(d.timingNote, '饭后');
      expect(d.issues, isEmpty);
      expect(d.readyToSave, isTrue);
    });

    test('三餐后（口语）展开成三次', () {
      final d = MedicationNlu.parse('三餐后各一片 阿卡波糖');
      expect(d.name, '阿卡波糖');
      expect(d.times, ['08:00', '12:30', '19:00']);
      // 时间是从「三餐」推出来的，必须提示确认
      expect(d.issues, isNotEmpty);
    });

    test('商品名映射到通用名', () {
      final d = MedicationNlu.parse('格华止 8:30 和 20:30 各一片');
      expect(d.name, '二甲双胍');
      expect(d.times, ['08:30', '20:30']);
    });

    test('每天 N 次但只说早晚，要提示数量对不上', () {
      final d = MedicationNlu.parse('一天两次 拜新同 两片 早上和晚上');
      expect(d.dosageValue, 2);
      expect(d.times, ['08:00', '20:00']);
    });
  });

  group('剂量表达', () {
    test('半片', () {
      expect(MedicationNlu.parse('每次半片 一天一次').dosageValue, 0.5);
    });

    test('一片半', () {
      expect(MedicationNlu.parse('一片半 晚上睡前').dosageValue, 1.5);
    });

    test('一百毫克', () {
      final d = MedicationNlu.parse('阿司匹林一百毫克 饭后 一天一次');
      expect(d.dosageValue, 100);
      expect(d.dosageUnit, 'mg');
    });

    test('剂量和钟点相邻时不能互相污染', () {
      final d = MedicationNlu.parse('络活喜 每天一次 早上7点 5毫克');
      expect(d.times, ['07:00']);
      expect(d.dosageValue, 5);
      expect(d.dosageUnit, 'mg');
      expect(d.issues, isEmpty);
    });
  });

  group('时间表达', () {
    test('中文钟点', () {
      expect(MedicationNlu.parse('降压药一片 早上八点').times, ['08:00']);
    });

    test('下午/晚上 自动进 12 小时制', () {
      expect(MedicationNlu.parse('晚上八点吃一片降压药').times, ['20:00']);
    });

    test('七点半', () {
      expect(MedicationNlu.parse('优甲乐 早上七点半 半片').times, ['07:30']);
    });

    test('睡前 压掉泛指的晚上', () {
      expect(MedicationNlu.parse('睡前一片 阿托伐他汀').times, ['21:30']);
      expect(MedicationNlu.parse('一片半 晚上睡前').times, ['21:30']);
    });
  });

  group('间隔型与缺字段', () {
    test('每八小时一次：V2 展开成多个具体钟点，不再有 interval 频次', () {
      final d = MedicationNlu.parse('每八小时一次，两粒');
      // V1 曾有 FrequencyType.interval，V2 统一成「具体时间点」，
      // 频次由时间点数量反推（多于一处 = 每日多次）
      expect(d.times.length, greaterThan(1));
      expect(d.times.first, '08:00');
      expect(d.frequency, FrequencyType.multi);
      expect(d.dosageValue, 2);
    });

    test('只有剂量没有药名：不能保存', () {
      final d = MedicationNlu.parse('每次半片 一天一次');
      expect(d.hasName, isFalse);
      expect(d.readyToSave, isFalse);
      expect(d.issues.any((e) => e.contains('药名')), isTrue);
    });

    test('只有药名没有剂量：不能保存', () {
      final d = MedicationNlu.parse('阿司匹林 早上八点');
      expect(d.hasDosage, isFalse);
      expect(d.readyToSave, isFalse);
      expect(d.uncertainFields.contains('dosage'), isTrue);
    });
  });

  group('容错：不猜关键值', () {
    test('置信度低于阈值时标记为待确认', () {
      final d = MedicationNlu.parse('降压药一片 早上八点');
      // 药名不是词典命中，属于推测
      expect(d.fieldConfidence['name']!, lessThan(0.7));
      expect(d.uncertainFields.contains('name'), isTrue);
    });

    test('间隔型缺起始时间时提示确认起始点', () {
      final d = MedicationNlu.parse('每八小时一次，两粒');
      expect(d.issues.any((e) => e.contains('起始时间')), isTrue);
    });
  });

  group('频次归一（V2 三值）', () {
    test('一个时间点 = 每日一次', () {
      expect(FrequencyType.infer(1), FrequencyType.once);
      expect(FrequencyType.infer(0), FrequencyType.once);
    });

    test('多个时间点 = 每日多次', () {
      expect(FrequencyType.infer(2), FrequencyType.multi);
      expect(FrequencyType.infer(5), FrequencyType.multi);
    });

    test('V1 的 interval 兼容读成 custom', () {
      expect(FrequencyType.fromName('interval'), FrequencyType.custom);
      expect(FrequencyType.fromName('daily'), FrequencyType.multi);
      expect(FrequencyType.fromName(null), FrequencyType.multi);
    });
  });

  _scheduleAndStatusTests();
}

/// 用药计划与服药状态的核心规则测试
///
/// 这些规则直接决定「这一顿到底算不算吃了」，所以单独成组。
void _scheduleAndStatusTests() {
  group('有效期覆盖（coversDay）', () {
    Medication med({DateTime? start, DateTime? end, bool enabled = true}) {
      return Medication(
        id: 'm1',
        name: '二甲双胍',
        dosageValue: 1,
        dosageUnit: '片',
        frequency: FrequencyType.multi,
        times: const <String>['08:00', '20:00'],
        startDate: start,
        endDate: end,
        enabled: enabled,
        createdAt: DateTime(2026, 1, 1),
      );
    }

    test('长期用药（不设结束日期）天天覆盖', () {
      final m = med(start: DateTime(2026, 1, 10));
      expect(m.coversDay(DateTime(2026, 1, 10)), isTrue);
      expect(m.coversDay(DateTime(2030, 6, 1)), isTrue);
    });

    test('开始日之前不覆盖，开始当天覆盖', () {
      final m = med(start: DateTime(2026, 3, 1), end: DateTime(2026, 3, 7));
      expect(m.coversDay(DateTime(2026, 2, 28)), isFalse);
      expect(m.coversDay(DateTime(2026, 3, 1)), isTrue);
    });

    test('结束当天仍然覆盖，次日不再覆盖', () {
      final m = med(start: DateTime(2026, 3, 1), end: DateTime(2026, 3, 7));
      expect(m.coversDay(DateTime(2026, 3, 7)), isTrue);
      expect(m.coversDay(DateTime(2026, 3, 8)), isFalse);
    });

    test('已停用的药不再覆盖', () {
      final m = med(start: DateTime(2026, 1, 1), enabled: false);
      expect(m.coversDay(DateTime(2026, 3, 1)), isFalse);
    });

    test('疗程到期与手动停用都能被识别', () {
      final ongoing = med(start: DateTime(2026, 1, 1));
      expect(ongoing.isOngoing, isTrue);
      expect(ongoing.hasEnded, isFalse);

      final past = med(start: DateTime(2026, 1, 1), end: DateTime(2026, 1, 5));
      expect(past.hasEnded, isTrue);
    });
  });

  group('四态判定', () {
    test('只有「已服药」算真的吃了', () {
      expect(IntakeStatus.taken.isTaken, isTrue);
      expect(IntakeStatus.skipped.isTaken, isFalse);
      expect(IntakeStatus.pending.isTaken, isFalse);
      expect(IntakeStatus.overdue.isTaken, isFalse);
    });

    test('用户有过反馈的只有 已服药/已跳过/待确认', () {
      expect(IntakeStatus.taken.hasUserFeedback, isTrue);
      expect(IntakeStatus.skipped.hasUserFeedback, isTrue);
      expect(IntakeStatus.pending.hasUserFeedback, isTrue);
      expect(IntakeStatus.overdue.hasUserFeedback, isFalse);
    });

    test('V1 的 snoozed / missed 兼容映射', () {
      expect(IntakeStatus.fromName('snoozed'), IntakeStatus.pending);
      expect(IntakeStatus.fromName('missed'), IntakeStatus.overdue);
      expect(IntakeStatus.fromName(null), IntakeStatus.pending);
    });

    final Medication base = Medication(
      id: 'm1',
      name: '二甲双胍',
      dosageValue: 1,
      dosageUnit: '片',
      frequency: FrequencyType.once,
      times: const <String>['08:00'],
      createdAt: DateTime(2026, 1, 1),
    );

    test('没有记录时到点超宽限期则显示逾期', () {
      final slot = DaySlot(med: base, planned: DateTime(2026, 3, 1, 8, 0));
      expect(slot.displayStatus(DateTime(2026, 3, 1, 8, 10)), IntakeStatus.pending);
      expect(slot.displayStatus(DateTime(2026, 3, 1, 8, 45)), IntakeStatus.overdue);
    });

    test('已点「待确认」但超时的，对外显示逾期', () {
      final slot = DaySlot(
        med: base,
        planned: DateTime(2026, 3, 1, 8, 0),
        status: IntakeStatus.pending,
      );
      expect(slot.displayStatus(DateTime(2026, 3, 1, 8, 10)), IntakeStatus.pending);
      expect(slot.displayStatus(DateTime(2026, 3, 1, 9, 0)), IntakeStatus.overdue);
    });

    test('已服药 / 已跳过不会被时间改写成逾期', () {
      for (final IntakeStatus s in <IntakeStatus>[
        IntakeStatus.taken,
        IntakeStatus.skipped,
      ]) {
        final slot = DaySlot(
          med: base,
          planned: DateTime(2026, 3, 1, 8, 0),
          status: s,
        );
        expect(slot.displayStatus(DateTime(2026, 3, 2, 8, 0)), s);
      }
    });
  });

  group('状态编码 pack/unpack', () {
    test('四种状态往返一致', () {
      for (final IntakeStatus s in IntakeStatus.values) {
        expect(unpackStatus(packStatus(s)), s);
      }
    });

    test('稍后提醒的分钟数能带上且不影响状态', () {
      final int packed = packStatus(IntakeStatus.pending, snoozeMinutes: 15);
      expect(unpackStatus(packed), IntakeStatus.pending);
      expect(unpackSnooze(packed), 15);
    });

    test('未设置延后时分钟数为 0', () {
      expect(unpackSnooze(packStatus(IntakeStatus.taken)), 0);
    });
  });

  group('时段构建 buildSlots', () {
    test('按当天覆盖情况生成时间点，并回填状态', () {
      final Medication m = Medication(
        id: 'm1',
        name: '二甲双胍',
        dosageValue: 1,
        dosageUnit: '片',
        frequency: FrequencyType.multi,
        times: const <String>['08:00', '20:00'],
        startDate: DateTime(2026, 3, 1),
        createdAt: DateTime(2026, 1, 1),
      );
      final DateTime day = DateTime(2026, 3, 2);
      final List<DaySlot> slots = buildSlots(
        <Medication>[m],
        day,
        <String, int>{slotKey('m1', DateTime(2026, 3, 2, 20, 0)): packStatus(IntakeStatus.taken)},
      );
      expect(slots.length, 2);
      expect(slots.first.planned, DateTime(2026, 3, 2, 8, 0));
      expect(slots.first.status, isNull);
      expect(slots.last.status, IntakeStatus.taken);
    });

    test('不在有效期内的日期不产生时间点', () {
      final Medication m = Medication(
        id: 'm1',
        name: '二甲双胍',
        dosageValue: 1,
        dosageUnit: '片',
        frequency: FrequencyType.once,
        times: const <String>['08:00'],
        endDate: DateTime(2026, 3, 1),
        createdAt: DateTime(2026, 1, 1),
      );
      expect(buildSlots(<Medication>[m], DateTime(2026, 3, 5), <String, int>{}), isEmpty);
    });
  });
}
