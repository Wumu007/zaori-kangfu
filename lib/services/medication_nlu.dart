import '../models/medication.dart';
import '../models/medication_draft.dart';

/// 中文口语用药解析器（纯 Dart，无 Flutter 依赖，可单测）
///
/// 输入：语音识别得到的整句文本，例如
///   「二甲双胍 每天两次 早晚各一片 饭后吃」
///   「降压药一片 早上八点」
///   「每八小时一次，两粒」
/// 输出：[MedicationDraft]，含字段级置信度与待确认问题。
///
/// 设计原则：**宁可标"不确定"，也不猜一个像模像样的值**。
/// 剂量和药名猜错会直接伤到人，所以置信度低就进 issues，交给确认卡片兜住。
class MedicationNlu {
  const MedicationNlu();

  // ---------------------------------------------------------------- 词表

  /// 常见药名 + 商品名（V1 内置词表；V2 可换成云端药典 + ASR 热词表）
  /// 全部标准药名 —— 在线识别的「热词表」直接用它，
  /// 保证「识别用词表」和「解析用词表」永远是同一份。
  static List<String> get drugNames => _lexicon.keys.toList();

  static const Map<String, List<String>> _lexicon = <String, List<String>>{
    '二甲双胍': ['二甲双胍', '格华止'],
    '阿司匹林': ['阿司匹林', '拜阿司匹林', '拜阿'],
    '氨氯地平': ['氨氯地平', '络活喜'],
    '硝苯地平': ['硝苯地平', '拜新同'],
    '缬沙坦': ['缬沙坦', '代文'],
    '厄贝沙坦': ['厄贝沙坦', '安博维'],
    '氯沙坦': ['氯沙坦', '科素亚'],
    '美托洛尔': ['美托洛尔', '倍他乐克'],
    '比索洛尔': ['比索洛尔', '康忻'],
    '阿托伐他汀': ['阿托伐他汀', '立普妥'],
    '瑞舒伐他汀': ['瑞舒伐他汀', '可定'],
    '辛伐他汀': ['辛伐他汀', '舒降之'],
    '左甲状腺素': ['左甲状腺素', '优甲乐'],
    '华法林': ['华法林'],
    '氯吡格雷': ['氯吡格雷', '波立维'],
    '格列美脲': ['格列美脲', '亚莫利'],
    '阿卡波糖': ['阿卡波糖', '拜唐苹'],
    '达格列净': ['达格列净', '安达唐'],
    '西格列汀': ['西格列汀', '捷诺维'],
    '奥美拉唑': ['奥美拉唑', '洛赛克'],
    '雷贝拉唑': ['雷贝拉唑', '波利特'],
    '碳酸钙': ['碳酸钙', '钙片'],
    '骨化三醇': ['骨化三醇', '罗盖全'],
    '维生素D': ['维生素d', '维生素D'],
    '布洛芬': ['布洛芬', '芬必得'],
    '对乙酰氨基酚': ['对乙酰氨基酚', '扑热息痛', '泰诺林'],
    '头孢克肟': ['头孢克肟'],
    '阿莫西林': ['阿莫西林'],
    '甲钴胺': ['甲钴胺', '弥可保'],
    '单硝酸异山梨酯': ['单硝酸异山梨酯', '欣康'],
    '呋塞米': ['呋塞米', '速尿'],
    '螺内酯': ['螺内酯', '安体舒通'],
    '别嘌醇': ['别嘌醇'],
    '非布司他': ['非布司他', '优立通'],
  };

  /// 单位别名 → 统一单位
  static const Map<String, String> _unitNormalize = <String, String>{
    '毫升': 'ml', 'ml': 'ml', 'mL': 'ml',
    '毫克': 'mg', 'mg': 'mg', 'MG': 'mg',
    '微克': 'μg', 'ug': 'μg', 'μg': 'μg',
    '克': 'g', 'g': 'g', 'G': 'g',
    '片剂': '片', '片': '片', '粒': '粒', '颗': '颗', '丸': '丸',
    '袋': '袋', '包': '包', '支': '支', '瓶': '瓶', '滴': '滴',
    '喷': '喷', '揿': '喷', '单位': 'U', 'iu': 'U', 'IU': 'U', 'U': 'U',
  };

  static const List<String> _unitTokens = <String>[
    '毫升', '毫克', '微克', '片剂', '单位',
    'μg', 'ug', 'ml', 'mL', 'mg', 'MG',
    '片', '粒', '颗', '丸', '袋', '包', '支', '瓶', '滴', '喷', '揿',
    'iu', 'IU', 'g', 'G', 'U',
  ];

  static const List<String> _periods = <String>[
    '凌晨', '清晨', '早上', '早晨', '清早', '上午', '中午',
    '下午', '傍晚', '晚上', '晚间', '夜里', '夜间', '睡前',
  ];

  /// 只说时段不说钟点时，按这些默认值预填（并标记为待确认）
  static const Map<String, List<int>> _periodDefault = <String, List<int>>{
    '凌晨': [5, 0], '清晨': [7, 0], '早上': [8, 0], '早晨': [8, 0],
    '清早': [7, 0], '上午': [9, 0], '中午': [12, 0], '下午': [15, 0],
    '傍晚': [18, 0], '晚上': [20, 0], '晚间': [20, 0],
    '夜里': [22, 0], '夜间': [22, 0], '睡前': [21, 30],
  };

  /// 未说时间、只说了每日次数时的常用分配方案
  static const Map<int, List<String>> _defaultDistribution =
      <int, List<String>>{
    1: ['08:00'],
    2: ['08:00', '20:00'],
    3: ['08:00', '12:30', '19:00'],
    4: ['08:00', '12:00', '17:00', '21:00'],
  };

  static const Set<String> _noteWords = <String>{
    '饭前', '饭后', '餐前', '餐后', '随餐', '空腹', '睡前', '早上空腹', '餐中',
  };

  /// 星期字样 → ISO 星期号（1=周一 … 7=周日）。
  ///
  /// 在**原始文本**上匹配：`_normalize` 会把「一三五」这类中文数字
  /// 合并成一个数字（135），星期几就再也还原不出来了。
  static const Map<String, int> _weekdayChar = <String, int>{
    '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '日': 7, '天': 7,
    '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7,
  };

  /// 紧跟数字后面时表示「数量」而不是「星期几」的字
  static const Set<String> _countUnits = <String>{
    '片', '粒', '颗', '丸', '袋', '包', '支', '瓶', '滴', '喷', '次', '顿',
  };

  static final String _unitPat = _unitTokens.join('|');
  static final String _periodPat = _periods.join('|');

  // ---------------------------------------------------------------- 正则

  static final RegExp _reClock = RegExp(
      '($_periodPat)?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{1,2})');
  static final RegExp _reHourPoint = RegExp(
      '($_periodPat)?\\s*(\\d{1,2})\\s*点\\s*(半|一刻|三刻|(\\d{1,2})\\s*分)?');
  static final RegExp _rePeriodOnly = RegExp('($_periodPat)');
  static final RegExp _reEveryHours =
      RegExp(r'(?:每|每隔)\s*(\d{1,2})\s*(?:个)?\s*小时');
  static final RegExp _reTimesPerDay = RegExp(r'每天\s*(\d{1,2})\s*次');
  static final RegExp _reDoseThenHalf =
      RegExp('(\\d+(?:\\.\\d+)?)\\s*($_unitPat)\\s*半');
  static final RegExp _reHalfDose = RegExp('半\\s*($_unitPat)');
  static final RegExp _reDose = RegExp('(\\d+(?:\\.\\d+)?)\\s*($_unitPat)');
  static final RegExp _reCjkRun = RegExp(r'[\u4e00-\u9fa5]{2,}');

  // ---------------------------------------------------------------- 入口

  /// 解析一句口语
  static MedicationDraft parse(String raw) {
    final draft = MedicationDraft(rawText: raw);
    // 药名在「原文」上匹配：中文数字归一化会把「二甲双胍」变成「2甲双胍」
    final lexName = _matchLexicon(raw);
    final source = _normalize(raw);
    var work = source;

    // 1) 间隔型：每 8 小时 —— 展开成从 08:00 起的一组具体时间点
    int? intervalHours;
    final mInterval = _reEveryHours.firstMatch(work);
    if (mInterval != null) {
      final int h = int.tryParse(mInterval.group(1)!) ?? 0;
      if (h > 0 && h <= 24) {
        intervalHours = h;
        work = _cut(work, mInterval.start, mInterval.end);
      }
    }

    // 2) 每周：星期几 / 每周 N 次（V1.12.0）
    //
    //    支持的说法：
    //      「每周一三五早上八点」「每星期二、四 晚上八点」「每周日」
    //      「每周三次」「每周两片」（总量说法，按每周 N 次拟）
    final _WeeklyHint? weekly = _parseWeekly(raw);
    if (weekly != null) {
      draft.repeat = RepeatType.weekly;
      draft.weekdays
        ..clear()
        ..addAll(weekly.weekdays);
      draft.fieldConfidence['repeat'] = weekly.exact ? 0.9 : 0.6;

      if (weekly.count != null) {
        final String days = weekly.weekdays
            .map((int w) => kWeekdayNames[w - 1])
            .join('、');
        draft.uncertainFields.add('weekdays');
        draft.issues.add('听到「每周 ${weekly.count} 次」的说法，'
            '已按每周$days各一次安排，请确认');
        // 「每周三片」里的 3 是总量而不是每次剂量，按每次 1 片拟并标黄
        if (draft.dosageValue == null) {
          draft.dosageValue = 1;
          draft.dosageUnit = '片';
          draft.uncertainFields.add('dosage');
        }
        // 把「每周3片」整段摘掉，别让剂量解析再抓一次「3片」
        work = work.replaceAll(
            RegExp('每\\s*(?:周|星期|礼拜)\\s*\\d+\\s*($_unitPat)'), ' ');
      }
      // 摘掉「每周」，避免影响后面的药名猜测
      work = work.replaceAll(RegExp('每\\s*(?:周|星期|礼拜)'), ' ');
    }

    // 3) 每日 N 次
    int? timesPerDay;
    final mCount = _reTimesPerDay.firstMatch(work);
    if (mCount != null) {
      timesPerDay = int.tryParse(mCount.group(1)!);
      work = _cut(work, mCount.start, mCount.end);
    }

    // 3) 带冒号的钟点：7:30 / 晚上 20:00
    work = _consume(work, _reClock, (m) {
      final period = m.group(1);
      var h = int.tryParse(m.group(2)!) ?? 0;
      final mi = int.tryParse(m.group(3)!) ?? 0;
      draft.periodHint ??= period;
      draft.times.add(_toHm(_applyHourPeriod(period, h), mi));
    });

    // 4) X 点 / X 点半 / X 点一刻
    work = _consume(work, _reHourPoint, (m) {
      final period = m.group(1);
      var h = int.tryParse(m.group(2)!) ?? 0;
      final suffix = m.group(3);
      var mi = 0;
      if (suffix == '半') {
        mi = 30;
      } else if (suffix == '一刻') {
        mi = 15;
      } else if (suffix == '三刻') {
        mi = 45;
      } else if (m.group(4) != null) {
        mi = int.tryParse(m.group(4)!) ?? 0;
      }
      draft.periodHint ??= period;
      draft.times.add(_toHm(_applyHourPeriod(period, h), mi));
    });

    // 5) 只有时段：早晚各一片 / 睡前一片
    if (draft.times.isEmpty) {
      // 「晚上睡前」这类叠说：睡前更具体，压掉泛指的晚上
      if (source.contains('睡前')) {
        work = work.replaceAll(RegExp('晚上|晚间|夜里|夜间'), ' ');
      }
      work = _consume(work, _rePeriodOnly, (m) {
        final p = m.group(1)!;
        final def = _periodDefault[p]!;
        draft.periodHint ??= p;
        draft.times.add(_toHm(def[0], def[1]));
      });
    }

    // 6) 剂量：1片半 > 1片 > 半片
    work = _consume(work, _reDoseThenHalf, (m) {
      final base = double.tryParse(m.group(1)!) ?? 0;
      draft.dosageValue = base + 0.5;
      draft.dosageUnit = _unitNormalize[m.group(2)!] ?? m.group(2)!;
    });
    if (draft.dosageValue == null) {
      work = _consume(work, _reDose, (m) {
        draft.dosageValue = double.tryParse(m.group(1)!);
        draft.dosageUnit = _unitNormalize[m.group(2)!] ?? m.group(2)!;
      });
    }
    if (draft.dosageValue == null) {
      work = _consume(work, _reHalfDose, (m) {
        draft.dosageValue = 0.5;
        draft.dosageUnit = _unitNormalize[m.group(1)!] ?? m.group(1)!;
      });
    }

    // 7) 服用时机备注
    for (final w in _noteWords) {
      if (source.contains(w)) {
        draft.timingNote = w;
        break;
      }
    }

    // 8) 药名：词表优先，其次从剩余文本里捞最长的中文串
    final hit = lexName ?? _matchLexicon(source);
    if (hit != null) {
      draft.name = hit;
      draft.fieldConfidence['name'] = 0.95;
      work = work.replaceAll(hit, ' ');
    } else {
      final String? guess = _guessNameFrom(work);
      // V1.13.0：识别出来的名字不在词表，但和某个标准药名只差一个字
      // （典型：非布斯他 → 非布司他、氨氯地平 → 安氯地平），
      // 按标准名纠正并标黄。距离 1 的同长度匹配很窄，误伤概率低。
      final String? near = guess == null ? null : _nearestDrugName(guess);
      if (near != null) {
        draft.name = near;
        draft.fieldConfidence['name'] = 0.7;
        draft.uncertainFields.add('name');
        draft.issues.add('听到「$guess」，已按「$near」理解，请确认');
        work = work.replaceAll(guess!, ' ');
      } else if (guess != null) {
        draft.name = guess;
        draft.fieldConfidence['name'] = 0.55;
        draft.uncertainFields.add('name');
      } else {
        draft.fieldConfidence['name'] = 0;
      }
    }

    // 9) 时间兜底：一句钟点都没听到时，按「每日 N 次」的常用分配预填；
    //    「每 N 小时」则从 08:00 起展开成具体时间点（不再保留间隔语义，
    //    因为调度层只认时间点，这样通知与记录才对得上）。
    if (draft.times.isEmpty && intervalHours != null) {
      var minutes = 8 * 60;
      while (draft.times.length < 6 && minutes < 24 * 60) {
        draft.times.add(_toHm(minutes ~/ 60, minutes % 60));
        minutes += intervalHours * 60;
      }
      draft.fieldConfidence['times'] = 0.7;
      draft.uncertainFields.add('times');
      draft.issues.add(
          '已按早上 8 点开始、每隔 $intervalHours 小时提醒，请确认起始时间');
    } else if (draft.times.isEmpty) {
      final int n = timesPerDay ?? 1;
      final List<String> plan = _defaultDistribution[n] ??
          List<String>.generate(n, (int i) => _toHm(8 + i * 3, 0));
      draft.times.addAll(plan);
      draft.fieldConfidence['times'] = 0.6;
      draft.uncertainFields.add('times');
      draft.issues.add('没听到具体钟点，已按每天 $n 次的常用时间预填，请确认');
    } else {
      draft.fieldConfidence['times'] =
          draft.periodHint != null && draft.times.isNotEmpty ? 0.9 : 0.75;
      // timesPerDay 与时间点数不一致时提示（如「每天三次」却只说了早晚）
      if (timesPerDay != null && draft.times.length != timesPerDay) {
        draft.issues.add('听到每天 $timesPerDay 次，但只识别到 '
            '${draft.times.length} 个时间点，请确认');
        draft.uncertainFields.add('times');
      }
    }

    // 9.5) 「一共两袋，每天早八点和晚七点」→ 这是**全天总量**，不是每次剂量
    //
    // 用户实测：说「中药两袋，每天早8点和晚7点」，表单填成「每次两袋」。
    //
    // 判据刻意收得很窄，只对**包装类单位**（袋 / 包）生效：
    // - 口语里「一天两袋」几乎都是总量（"两袋"指两包药）；
    // - 而「两片 / 两粒」既可能是每次也可能是总量，语义模糊，
    //   交给用户自己改更安全（也有既有用例依赖这一点）。
    // 另外要求剂量数字等于时间点个数、且原文没有「各 / 每次 / 一顿」。
    final bool packageUnit =
        draft.dosageUnit == '袋' || draft.dosageUnit == '包';
    if (packageUnit &&
        draft.dosageValue != null &&
        draft.times.length >= 2 &&
        draft.dosageValue == draft.times.length.toDouble() &&
        !source.contains('各') &&
        !source.contains('每次') &&
        !source.contains('一顿')) {
      final double total = draft.dosageValue!;
      final int n = draft.times.length;
      final double per = total / n;
      draft.dosageValue = per;
      draft.uncertainFields.add('dosage');
      draft.issues.add('听到「一共 ${_fmtNum(total)}${draft.dosageUnit ?? ''}、'
          '每天 $n 次」，已按每次 ${_fmtNum(per)}${draft.dosageUnit ?? ''} 安排，请确认');
    }

    // 10) 剂量置信度与缺失提示
    if (draft.dosageValue == null || draft.dosageUnit == null) {
      draft.fieldConfidence['dosage'] = 0;
      draft.issues.add('没听清每次吃多少，请补充（如「一片」「两粒」）');
      draft.uncertainFields.add('dosage');
    } else {
      draft.fieldConfidence['dosage'] = 0.95;
    }

    if (!draft.hasName) {
      draft.issues.add('没听清药名，请重说或手动填写');
    }

    // 11) 去重 + 排序，并按时间点数量回填频次
    final List<String> uniq = <String>[];
    for (final String t in draft.times) {
      if (!uniq.contains(t)) uniq.add(t);
    }
    uniq.sort();
    draft.times
      ..clear()
      ..addAll(uniq);

    draft.frequency = FrequencyType.infer(draft.times.length);
    return draft;
  }

  // ---------------------------------------------------------------- 每周

  /// 解析「每周…」描述。返回 null 表示这句话不是按周服用的。
  static _WeeklyHint? _parseWeekly(String raw) {
    final Match? head = RegExp('每\\s*(?:周|星期|礼拜)').firstMatch(raw);
    if (head == null) return null;

    // 识别结果里的空格可能是**全角空格**（U+3000）或不换行空格（U+00A0），
    // 用 `ch == ' '` 比较会漏判 —— 用户实测「每周二 周五吃」只选中了周二，
    // 就是因为在全角空格处直接 break 了。这里先统一压成半角空格。
    final String rest = raw
        .substring(head.end)
        .replaceAll(RegExp('[\\s\\u3000\\u00a0]+'), ' ');

    final List<int> days = <int>[];
    int? count;
    int i = 0;

    while (i < rest.length) {
      final String ch = rest[i];
      final int? wd = _weekdayChar[ch];
      if (wd != null) {
        final String? next = i + 1 < rest.length ? rest[i + 1] : null;
        // 「每周三片」「每周三次」：后面紧跟单位 → 这是数量，不是星期三
        if (next != null && _countUnits.contains(next)) {
          count = wd;
          break;
        }
        days.add(wd);
        i++;
        continue;
      }
      // 分隔符继续往后读（「每周一、三、五」「每周二，周五」）
      if (ch == ' ' || ch == '、' || ch == ',' || ch == '，' ||
          ch == '。' || ch == '和' || ch == '及' || ch == '与') {
        i++;
        continue;
      }
      // 「周二周五」连写：跳过「周/星期/礼拜」继续读下一个星期
      if (ch == '周' || ch == '星' || ch == '期' || ch == '礼' || ch == '拜') {
        i++;
        continue;
      }
      break;
    }

    if (days.isEmpty && count == null) return null;

    if (days.isEmpty) {
      // 「每周 N 次」：均匀摊到一周（周一/周三/周五…）
      return _WeeklyHint(
        weekdays: _spreadWeekdays(count!),
        count: count,
      );
    }

    final List<int> uniq = <int>[];
    for (final int d in days) {
      if (!uniq.contains(d)) uniq.add(d);
    }
    uniq.sort();
    return _WeeklyHint(weekdays: uniq);
  }

  /// 把「每周 N 次」均匀摊到一周
  static List<int> _spreadWeekdays(int n) {
    final int cnt = n.clamp(1, 7);
    if (cnt == 1) return <int>[DateTime.monday];
    final List<int> out = <int>[];
    for (int i = 0; i < cnt; i++) {
      final int w = (i * 7 ~/ cnt) + 1;
      if (!out.contains(w)) out.add(w);
    }
    return out;
  }

  // ---------------------------------------------------------------- 工具

  /// 找「只差一个字」的标准药名（长度相同、编辑距离 1）
  static String? _nearestDrugName(String guess) {
    final String g = guess.trim();
    if (g.length < 3 || g.length > 6) return null;
    for (final String key in _lexicon.keys) {
      if (key.length != g.length) continue;
      if (_editDistance(key, g) == 1) return key;
    }
    return null;
  }

  /// 编辑距离（只用来判断「差一个字」）
  static int _editDistance(String a, String b) {
    final List<int> prev = List<int>.generate(b.length + 1, (int i) => i);
    for (int i = 1; i <= a.length; i++) {
      int last = prev[0];
      prev[0] = i;
      for (int j = 1; j <= b.length; j++) {
        final int old = prev[j];
        final int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        prev[j] = [prev[j] + 1, prev[j - 1] + 1, last + cost]
            .reduce((int x, int y) => x < y ? x : y);
        last = old;
      }
    }
    return prev[b.length];
  }

  /// 数字转文案：1.0 → 1，0.5 → 0.5
  static String _fmtNum(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  static String _toHm(int hour, int minute) {
    var h = hour % 24;
    var m = minute;
    if (m >= 60) {
      h = (h + m ~/ 60) % 24;
      m = m % 60;
    }
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static int _applyHourPeriod(String? period, int hour) {
    if (period == null) return hour;
    const pm = <String>{'下午', '傍晚', '晚上', '晚间', '夜里', '夜间', '睡前'};
    if (pm.contains(period)) {
      if (hour >= 1 && hour <= 11) return hour + 12;
      return hour;
    }
    if (period == '中午') {
      if (hour <= 3) return hour + 12;
      return hour;
    }
    return hour;
  }

  static String _cut(String s, int start, int end) =>
      s.replaceRange(start, end, ' ');

  /// 反复匹配直到没有，逐次消费文本
  static String _consume(
      String input, RegExp re, void Function(RegExpMatch m) onMatch) {
    var work = input;
    while (true) {
      final m = re.firstMatch(work);
      if (m == null) break;
      onMatch(m);
      work = _cut(work, m.start, m.end);
    }
    return work;
  }

  static String? _matchLexicon(String source) {
    final lower = source.toLowerCase();
    String? best;
    for (final entry in _lexicon.entries) {
      for (final alias in entry.value) {
        if (lower.contains(alias.toLowerCase())) {
          if (best == null || entry.key.length > best.length) {
            best = entry.key;
          }
        }
      }
    }
    return best;
  }

  /// 「半片」「两粒」「每次」「一天一次」这类是数量/频次，不是药名。
  /// 不排除掉的话，「每次半片 一天一次」会被兜底猜成药名「每次」，
  /// 保存按钮就会错误地变绿——这是最危险的一类误判。
  static final RegExp _reDoseOrFrequency = RegExp(
      r'^(每|一|二|三|四|五|六|七|八|九|十|半|两|几|\d)+'
      r'(次|回|片|粒|袋|支|瓶|盒|滴|毫升|毫克|克|单位|天|日|小时|分钟|点|个)?$');

  static String? _guessNameFrom(String residual) {
    final runs = _reCjkRun.allMatches(residual).map((m) => m.group(0)!).toList();
    if (runs.isEmpty) return null;
    runs.sort((a, b) => b.length.compareTo(a.length));
    for (final r in runs) {
      final cleaned = _stripStopwords(r);
      if (cleaned.length < 2) continue;
      // 纯数量/频次词（半片、两粒、每次…）不算药名，宁可留空让用户补
      if (_reDoseOrFrequency.hasMatch(cleaned)) continue;
      return cleaned;
    }
    return null;
  }

  static const Set<String> _stopPrefixes = <String>{
    '我', '要', '该', '吃', '喝', '服用', '记得', '提醒', '帮我', '帮', '请',
    '这个', '那个', '还有', '然后', '和', '跟', '每次', '每天', '现在', '医生',
    '开', '说', '一共', '早上', '晚上', '中午', '下午', '上午', '睡前', '饭后',
    '饭前', '空腹', '随餐',
  };

  static String _stripStopwords(String input) {
    var s = input;
    var changed = true;
    while (changed && s.length > 2) {
      changed = false;
      for (final p in _stopPrefixes) {
        if (s.startsWith(p) && s.length - p.length >= 2) {
          s = s.substring(p.length);
          changed = true;
        }
        if (s.endsWith(p) && s.length - p.length >= 2) {
          s = s.substring(0, s.length - p.length);
          changed = true;
        }
      }
    }
    return s;
  }

  // ---------------------------------------------------------- 文本规范化

  static String _normalize(String raw) {
    var s = raw.trim();
    // 全角 → 半角
    final buf = StringBuffer();
    for (final code in s.codeUnits) {
      if (code >= 0xFF01 && code <= 0xFF5E) {
        buf.writeCharCode(code - 0xFEE0);
      } else if (code == 0x3000) {
        buf.write(' ');
      } else {
        buf.writeCharCode(code);
      }
    }
    s = buf.toString();
    // 口语归一：老人常说「早晚」「早中晚」「三餐」，先展开成标准说法
    s = s.replaceAll('三餐后', '每天三次 饭后');
    s = s.replaceAll('三餐前', '每天三次 饭前');
    s = s.replaceAll('三餐', '每天三次');
    s = s.replaceAll('早中晚', '早上 中午 晚上');
    s = s.replaceAll('早晚', '早上 晚上');
    s = s.replaceAll(RegExp(r'一日|一天|1天|每天|每日|天天'), '每天');
    // 去中文标点，保留 '.' ':' 以免破坏小数与时间
    s = s.replaceAll(RegExp(r'[，,。、；;！!？?]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 中文数字 → 阿拉伯数字
    return _convertChineseNumbers(s);
  }

  static const Map<String, int> _cnDigits = <String, int>{
    '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };

  static const Map<String, int> _cnUnits = <String, int>{
    '十': 10, '廿': 20, '百': 100, '千': 1000,
  };

  static String _convertChineseNumbers(String s) {
    final out = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (_cnDigits.containsKey(ch) || _cnUnits.containsKey(ch)) {
        var j = i;
        while (j < s.length &&
            (_cnDigits.containsKey(s[j]) || _cnUnits.containsKey(s[j]))) {
          j++;
        }
        out.write(_cnToArabic(s.substring(i, j)));
        i = j;
      } else {
        out.write(ch);
        i++;
      }
    }
    return out.toString();
  }

  /// 支持 十 / 十二 / 二十三 / 一百二十 / 两
  static int _cnToArabic(String s) {
    var result = 0;
    var current = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (_cnDigits.containsKey(ch)) {
        current = _cnDigits[ch]!;
      } else if (_cnUnits.containsKey(ch)) {
        final u = _cnUnits[ch]!;
        if (current == 0) current = 1;
        if (u == 20) {
          // 廿
          result += 20;
        } else {
          result += current * u;
        }
        current = 0;
      }
    }
    return result + current;
  }
}

/// 「每周…」的解析结果
class _WeeklyHint {
  const _WeeklyHint({required this.weekdays, this.count});

  /// 星期号（ISO 1..7），已去重排序
  final List<int> weekdays;

  /// 非空表示听到的是「每周 N 次」这种总量说法，需要标黄确认
  final int? count;

  /// 星期几是明确说出来的（而不是从次数推出来的）
  bool get exact => count == null;
}
