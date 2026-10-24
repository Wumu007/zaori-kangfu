import 'medication.dart';

/// 语音录入解析出来的「草稿」
///
/// 关键设计：**它不是一个可以直接落库的对象**。
/// 每个字段都带独立置信度，缺字段就进 issues，必须由用户在确认卡片上
/// 逐项看一遍才能保存 —— 语音识别的错不能变成吃错药的错。
class MedicationDraft {
  MedicationDraft({required this.rawText});

  /// 用户原话（保留用于「重听/重说」对比与手工纠错）
  final String rawText;

  String? name;
  double? dosageValue;
  String? dosageUnit;
  FrequencyType frequency = FrequencyType.once;

  /// 重复周期（V1.12.0：语音也能说「每周一三五」）
  RepeatType repeat = RepeatType.daily;

  /// 每周服药的星期号（ISO：1=周一 … 7=周日），仅 weekly 有效
  final List<int> weekdays = <int>[];

  /// 解析出的每日时间点 'HH:mm'
  final List<String> times = <String>[];
  String? timingNote;

  /// 语音里提到的时段（早上/晚上/睡前），用于兜底与回读文案
  String? periodHint;

  /// 必须让用户确认/补录的问题项
  final List<String> issues = <String>[];

  /// 字段级置信度：name / dosage / times，取值 0~1
  final Map<String, double> fieldConfidence = <String, double>{};

  /// 哪些字段是「推测」出来的，UI 用橙色标记 + 「请确认」
  final Set<String> uncertainFields = <String>{};

  double get confidence {
    if (fieldConfidence.isEmpty) return 0;
    final double avg =
        fieldConfidence.values.reduce((double a, double b) => a + b) /
            fieldConfidence.length;
    final double penalty = issues.length * 0.08;
    final double v = avg - penalty;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  bool get hasName => name != null && name!.trim().isNotEmpty;
  bool get hasDosage => dosageValue != null && dosageUnit != null;
  bool get hasTimes => times.isNotEmpty;

  /// 安全门禁：药名、剂量、时间三者齐全才允许保存
  bool get readyToSave => hasName && hasDosage && hasTimes;

  /// 回读文案（TTS 用）：「我听到的是 二甲双胍，每次 1 片，早上 8 点各一次，对吗？」
  String get readBackText {
    final StringBuffer b = StringBuffer('我听到的是：');
    b.write(hasName ? name! : '药名没听清');
    b.write('，每次 ');
    b.write(hasDosage ? '${_fmtNum(dosageValue!)}${_unitForSpeech(dosageUnit!)}' : '剂量没听清');
    if (repeat == RepeatType.weekly && weekdays.isNotEmpty) {
      b.write('，每周');
      b.write(weekdays.map((int w) => kWeekdayNames[w - 1]).join('、'));
      if (hasTimes) {
        b.write('，');
        b.write(_speakTimes(times));
      } else {
        b.write('，时间没听清');
      }
    } else if (hasTimes) {
      b.write('，');
      b.write(_speakTimes(times));
    } else {
      b.write('，时间没听清');
    }
    if (timingNote != null) b.write('，${timingNote!}');
    b.write('。对吗？');
    return b.toString();
  }

  /// 转成可落库的 Medication
  Medication toMedication({
    String? id,
    DateTime? startDate,
    DateTime? endDate,
    String? note,
  }) {
    assert(readyToSave, '剂量/药名/时间不完整时禁止落库');
    final List<String> sorted = List<String>.from(times)..sort();
    return Medication(
      id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name!.trim(),
      dosageValue: dosageValue!,
      dosageUnit: dosageUnit!,
      frequency: FrequencyType.infer(sorted.length),
      times: sorted,
      repeat: repeat,
      weekdays: repeat == RepeatType.weekly ? List<int>.from(weekdays) : null,
      note: note ?? timingNote,
      startDate: startDate,
      endDate: endDate,
      createdAt: DateTime.now(),
    );
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static String _unitForSpeech(String unit) {
    const Map<String, String> map = <String, String>{
      'ml': '毫升',
      'mg': '毫克',
      'μg': '微克',
      'g': '克',
      'U': '单位',
      '单位': '单位',
    };
    return map[unit] ?? unit;
  }

  static String _speakTimes(List<String> times) {
    final List<String> label = <String>[];
    for (final String t in times) {
      final int h = int.parse(t.split(':')[0]);
      final int m = int.parse(t.split(':')[1]);
      final String period = h < 6
          ? '凌晨'
          : h < 11
              ? '早上'
              : h < 13
                  ? '中午'
                  : h < 18
                      ? '下午'
                      : '晚上';
      final int hh = h > 12 ? h - 12 : (h == 0 ? 12 : h);
      label.add('$period $hh 点${m == 0 ? '' : ' $m 分'}');
    }
    return '${label.join('、')}各一次';
  }
}
