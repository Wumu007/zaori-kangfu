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
  FrequencyType frequency = FrequencyType.daily;
  int? intervalHours;

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
    final avg =
        fieldConfidence.values.reduce((a, b) => a + b) / fieldConfidence.length;
    final penalty = issues.length * 0.08;
    final v = avg - penalty;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  bool get hasName => name != null && name!.trim().isNotEmpty;
  bool get hasDosage => dosageValue != null && dosageUnit != null;
  bool get hasTimes => times.isNotEmpty;

  /// 安全门禁：药名、剂量、时间三者齐全才允许保存
  bool get readyToSave => hasName && hasDosage && hasTimes;

  /// 回读文案（TTS 用）：「我听到的是 二甲双胍，每次 1 片，早上 8 点，对吗？」
  String get readBackText {
    final b = StringBuffer('我听到的是：');
    b.write(hasName ? name! : '药名没听清');
    b.write('，每次 ');
    b.write(hasDosage ? '$dosageValue${_unitForSpeech(dosageUnit!)}' : '剂量没听清');
    if (hasTimes) {
      b.write('，');
      b.write(frequency == FrequencyType.interval
          ? '每隔 $intervalHours 小时一次'
          : _speakTimes(times));
    } else {
      b.write('，时间没听清');
    }
    if (timingNote != null) b.write('，${timingNote!}');
    b.write('。对吗？');
    return b.toString();
  }

  /// 转成可落库的 Medication
  Medication toMedication({String? id}) {
    assert(readyToSave, '剂量/药名/时间不完整时禁止落库');
    final sorted = List<String>.from(times)..sort();
    return Medication(
      id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name!.trim(),
      dosageValue: dosageValue!,
      dosageUnit: dosageUnit!,
      frequency: frequency,
      times: _expandInterval(sorted),
      intervalHours: intervalHours,
      note: timingNote,
      createdAt: DateTime.now(),
    );
  }

  /// interval 型展开成一天内的具体时间点（最多 6 次，防止「每小时」刷屏）
  List<String> _expandInterval(List<String> base) {
    if (frequency != FrequencyType.interval ||
        intervalHours == null ||
        intervalHours! <= 0) {
      return base;
    }
    final start = base.isNotEmpty ? base.first : '08:00';
    final parts = start.split(':');
    var minutes = int.parse(parts[0]) * 60 + int.parse(parts[1]);
    final out = <String>[];
    while (out.length < 6) {
      if (minutes >= 24 * 60) break;
      out.add(_fmt(minutes));
      minutes += intervalHours! * 60;
    }
    return out;
  }

  static String _fmt(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _unitForSpeech(String unit) {
    const map = {'ml': '毫升', 'mg': '毫克', 'μg': '微克', 'g': '克', 'U': '单位'};
    return map[unit] ?? unit;
  }

  static String _speakTimes(List<String> times) {
    final label = <String>[];
    for (final t in times) {
      final h = int.parse(t.split(':')[0]);
      final m = int.parse(t.split(':')[1]);
      final period = h < 6
          ? '凌晨'
          : h < 11
              ? '早上'
              : h < 13
                  ? '中午'
                  : h < 18
                      ? '下午'
                      : '晚上';
      final hh = h > 12 ? h - 12 : (h == 0 ? 12 : h);
      label.add('$period $hh 点${m == 0 ? '' : ' $m 分'}');
    }
    return '${label.join('、')}各一次';
  }
}
