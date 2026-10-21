import 'package:flutter_test/flutter_test.dart';
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
    test('每八小时一次', () {
      final d = MedicationNlu.parse('每八小时一次，两粒');
      expect(d.frequency, FrequencyType.interval);
      expect(d.intervalHours, 8);
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
}
