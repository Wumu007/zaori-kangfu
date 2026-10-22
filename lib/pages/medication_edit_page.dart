import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medication.dart';
import '../models/medication_draft.dart';
import '../services/medication_nlu.dart';
import '../services/voice_input_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/ui_kit.dart';

/// 药品录入 / 编辑页
///
/// 一屏两种录入方式，**共用同一份表单状态**：
/// - 键盘：直接改 [_name]、[_dose]、[_times] 这些字段；
/// - 语音：说一句话，解析成草稿后**回填到同一份字段**，用户核对再保存。
///
/// 这样就不会出现「语音录入的药品和键盘录入的药品存在两个不同的地方」，
/// 也让「语音听错一个字 → 直接用键盘改那个字」成为可能。
///
/// 安全红线（沿用 V1 的结论）：药名、剂量、时间三者不全就禁用保存，
/// 绝不给默认剂量 —— 少一次录入比吃错药代价小得多。
class MedicationEditPage extends StatefulWidget {
  const MedicationEditPage({super.key, this.med, this.voiceFirst = false});

  /// 非空 = 编辑已有药品；为空 = 新增
  final Medication? med;

  /// 进来就直接开麦（首页/列表页的「语音添加」走这条）
  final bool voiceFirst;

  @override
  State<MedicationEditPage> createState() => _MedicationEditPageState();
}

class _MedicationEditPageState extends State<MedicationEditPage>
    with SingleTickerProviderStateMixin {
  final VoiceInputService _voice = VoiceInputService();
  late final AnimationController _wave =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  // --- 表单状态 -------------------------------------------------------------

  late final TextEditingController _nameCtrl;
  late final TextEditingController _doseCtrl;
  String _unit = '片';
  final List<String> _times = <String>[];

  /// 每个时间点的独立剂量（键 = 'HH:mm'，值 = 剂量文本；空 = 用默认剂量）。
  /// 支持「早上 1 片、晚上半片」这类每顿不同的医嘱。
  final Map<String, String> _timeDoses = <String, String>{};
  RepeatType _repeat = RepeatType.daily;
  final Set<int> _weekdays = <int>{DateTime.monday};
  final Set<int> _monthDays = <int>{1};
  String? _note;
  DateTime? _startDate;
  DateTime? _endDate;

  /// 语音听错而没被用户确认过的字段（标黄提示，但不阻止保存）
  final Set<String> _uncertain = <String>{};
  List<String> _issues = const <String>[];

  // --- 语音状态 -------------------------------------------------------------

  bool _listening = false;
  bool _saving = false;

  /// 已确认的识别文本（多段 final 依次拼接；中文之间不加空格）
  String _finalBuf = '';

  /// 正在说的这句话的实时部分结果（随说话不断变长）
  String _partial = '';

  /// 识别结束后的可编辑结果框（用户可以改字再重新填入）
  final TextEditingController _resultCtrl = TextEditingController();
  bool _showResult = false;
  String _voiceError = '';

  /// 麦克风被「永久拒绝」时为 true：错误提示里给一个直接跳系统设置的链接
  bool _micBlocked = false;

  /// 这台手机根本没有可用的语音服务（未装 Google、系统语音组件被精简等）。
  ///
  /// V1.4.0 新增：真机上「说话没反应」的主因就是这种情况 ——
  /// 识别器起不来，界面上却一直显示「正在听」。此时必须停止提供语音入口，
  /// 直接把用户导向键盘输入，而不是让他反复对着手机说话。
  bool _voiceFatal = false;

  /// 此刻屏幕上应该显示的识别内容 = 已确认部分 + 正在说的部分
  String get _liveText => _finalBuf + _partial;

  bool get _isEdit => widget.med != null;

  @override
  void initState() {
    super.initState();
    final Medication? m = widget.med;
    _nameCtrl = TextEditingController(text: m?.name ?? '');
    _doseCtrl = TextEditingController(
      text: m == null ? '' : _fmtNum(m.dosageValue),
    );
    _unit = m?.dosageUnit ?? '片';
    if (m != null) {
      _times.addAll(m.times);
      _note = m.note;
      _startDate = m.startDate;
      _endDate = m.endDate;
      _repeat = m.repeat;
      _weekdays
        ..clear()
        ..addAll(m.weekdays);
      _monthDays
        ..clear()
        ..addAll(m.monthDays);
      for (int i = 0; i < m.times.length; i++) {
        final double? v = m.doseValues == null || i >= m.doseValues!.length
            ? null
            : m.doseValues![i];
        // 与默认剂量相同的独立剂量没有存在意义，不进 map
        if (v != null && v != m.dosageValue) {
          _timeDoses[m.times[i]] = _fmtNum(v);
        }
      }
    } else {
      _startDate = DateTime.now();
    }

    _nameCtrl.addListener(_onFieldChanged);
    _doseCtrl.addListener(_onFieldChanged);

    if (widget.voiceFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startVoice());
    }
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_onFieldChanged);
    _doseCtrl.removeListener(_onFieldChanged);
    _nameCtrl.dispose();
    _doseCtrl.dispose();
    _resultCtrl.dispose();
    _wave.dispose();
    _voice.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // 语音：实时转写 → 结束自动填入 → 结果可改再重新填入
  // ---------------------------------------------------------------------------

  Future<void> _startVoice() async {
    // 上一轮的「无语音服务」结论不清空：重试也没用，留着让用户看到真实原因；
    // 但麦克风被拒的标记要清，因为用户可能刚从系统设置里开了权限回来。
    if (_voiceFatal) return;
    setState(() {
      _listening = true;
      _finalBuf = '';
      _partial = '';
      _showResult = false;
      _voiceError = '';
      _micBlocked = false;
    });

    // 麦克风权限在第一次点语音时才申请（不在启动时打扰）
    final bool ok = await _voice.start(
      onPartial: (String t) {
        if (!mounted) return;
        setState(() => _partial = t);
      },
      onFinal: (String t) {
        if (!mounted) return;
        // 一大段话会被系统断成多段 final，逐段拼接，不能只留最后一段
        setState(() {
          _finalBuf += t;
          _partial = '';
        });
      },
      onError: (String msg) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _voiceError = msg;
        });
      },
      // V1.4.0：按失败类型决定要不要给「去装语音服务」的出口。
      // 没有语音服务时是这台手机真的不支持，不该让老人反复重说。
      onFailure: (AsrFailure kind, String msg) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _voiceError = msg;
          _voiceFatal = kind == AsrFailure.noEngine;
        });
      },
      onMicBlocked: (MicGate gate) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _micBlocked = gate == MicGate.permanentlyDenied;
        });
      },
      // 识别会话结束（自然停/超时/系统打断）→ 同步退出收音态。
      // V1.2「一直显示正在听」就是因为会话死了 UI 不知道。
      onStopped: () {
        if (!mounted || !_listening) return;
        setState(() => _listening = false);
        final String text = _liveText.trim();
        if (text.isEmpty) {
          setState(() {
            _voiceError = '没听到声音，再说一次，或者直接用下面的键盘填写';
          });
          return;
        }
        _finishWithText(text);
      },
    );
    if (!ok && mounted) {
      setState(() => _listening = false);
    }
  }

  Future<void> _stopAndParse() async {
    await _voice.stop();
    if (!mounted) return;
    final String text = _liveText.trim();
    if (text.isEmpty) {
      setState(() {
        _listening = false;
        _voiceError = '没听到声音，再说一次，或者直接用下面的键盘填写';
      });
      return;
    }
    setState(() => _listening = false);
    _finishWithText(text);
  }

  /// 识别完成：文本放进可编辑结果框，自动解析填入表单
  void _finishWithText(String text) {
    setState(() {
      _showResult = true;
      _resultCtrl.text = text;
    });
    _applyVoice(text);
  }

  /// 用户改了识别文字后重新填入
  void _reapplyResult() {
    final String text = _resultCtrl.text.trim();
    if (text.isEmpty) {
      showAppToast(context, '识别文字是空的');
      return;
    }
    _applyVoice(text);
  }

  /// 语音识别结果 → 解析并回填表单（填入后仍可手动修改任何字段）
  void _applyVoice(String text) {
    final MedicationDraft d = MedicationNlu.parse(text);
    setState(() {
      if (d.hasName) _nameCtrl.text = d.name!;
      if (d.hasDosage) {
        _doseCtrl.text = _fmtNum(d.dosageValue!);
        _unit = d.dosageUnit!;
      }
      if (d.hasTimes) {
        _times
          ..clear()
          ..addAll(d.times);
        _syncFrequencyByTimes();
      }
      if (d.timingNote != null) _note = d.timingNote;

      // 语音推测出来的字段一律标黄，让用户自己扫一眼
      _uncertain
        ..clear()
        ..addAll(d.uncertainFields);
      if (!d.hasDosage) _uncertain.add('dosage');
      if (!d.hasName) _uncertain.add('name');
      _issues = List<String>.from(d.issues);
    });

    // 缺什么就直接念出来，别让用户自己找
    _voice.speak(_issues.isNotEmpty ? _issues.first : d.readBackText);
  }

  // ---------------------------------------------------------------------------
  // 表单编辑
  // ---------------------------------------------------------------------------

  /// 语音填入后的整理：时间点排序。频次由时间点数量自然表达，无需单独维护。
  void _syncFrequencyByTimes() {
    _times.sort();
  }

  /// 切换重复周期（每天 / 每周 / 每月）
  void _onRepeatChanged(RepeatType r) {
    setState(() => _repeat = r);
  }

  Future<void> _addTime() async {
    if (_times.length >= 8) {
      _toast('一天最多 8 个时间点，够用了');
      return;
    }
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _times.isEmpty
          ? const TimeOfDay(hour: 8, minute: 0)
          : _parseHm(_times.last),
      helpText: '选择提醒时间',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    final String hm = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (_times.contains(hm)) {
      _toast('这个时间已经加过了');
      return;
    }
    setState(() {
      _times.add(hm);
      _times.sort();
      _uncertain.remove('times');
    });
  }

  /// 点某个时间点：改时间本身、改这一顿的独立剂量、或删除
  Future<void> _editTime(String hm) async {
    final String? removed = await _timeDoseDialog(hm);
    if (removed != null && mounted) {
      setState(() {
        _times.remove(removed);
        _timeDoses.remove(removed);
      });
    }
  }

  /// 编辑时间与剂量的弹窗。
  /// 返回 null = 取消；返回旧时间点字符串 = 删除了该时间点；
  /// 返回 'ok' = 完成了修改（时间/剂量已在内部更新）。
  Future<String?> _timeDoseDialog(String hm) async {
    TimeOfDay picked = _parseHm(hm);
    final TextEditingController doseCtrl =
        TextEditingController(text: _timeDoses[hm] ?? '');
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(VoidCallback) setDlg) {
          return AlertDialog(
            title: const Text('这一顿的时间和剂量'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                GestureDetector(
                  onTap: () async {
                    final TimeOfDay? t = await showTimePicker(
                      context: ctx,
                      initialTime: picked,
                      helpText: '选择提醒时间',
                      cancelText: '取消',
                      confirmText: '确定',
                    );
                    if (t != null) setDlg(() => picked = t);
                  },
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.badge),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.schedule_rounded,
                            size: 16, color: AppColors.faint),
                        const SizedBox(width: 8),
                        Text(
                          '${picked.hour.toString().padLeft(2, '0')}:'
                          '${picked.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            fontSize: AppText.bodySm,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                        ),
                        const Spacer(),
                        const Text(
                          '点这里改时间',
                          style: TextStyle(
                              fontSize: AppText.tiny, color: AppColors.faint),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: doseCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style:
                      const TextStyle(fontSize: AppText.body, color: AppColors.ink),
                  decoration: InputDecoration(
                    hintText: '留空 = 用默认剂量 $_doseCtrlHint',
                    hintStyle: const TextStyle(
                        fontSize: AppText.caption, color: AppColors.faint),
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 13),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.badge),
                      borderSide: const BorderSide(color: AppColors.line),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '适合「早上 1 片、晚上半片」这种每顿不一样的医嘱',
                  style: TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('DELETE'),
                child: const Text(
                  '删除',
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('OK'),
                child: const Text('确定', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          );
        },
      ),
    );
    final String doseText = doseCtrl.text.trim();
    doseCtrl.dispose();
    if (!mounted) return null;

    if (action == 'DELETE') return hm;

    if (action == 'OK') {
      final String newHm =
          '${picked.hour.toString().padLeft(2, '0')}:'
          '${picked.minute.toString().padLeft(2, '0')}';
      if (_times.contains(newHm) && newHm != hm) {
        _toast('这个时间已经加过了');
        return null;
      }
      setState(() {
        // 改时间：把旧时间点（连同它的独立剂量）迁到新时间点
        if (newHm != hm) {
          final String? oldDose = _timeDoses.remove(hm);
          _times.remove(hm);
          if (!_times.contains(newHm)) _times.add(newHm);
          _times.sort();
          if (oldDose != null) _timeDoses[newHm] = oldDose;
        }
        // 改剂量：填了就记独立剂量，清空则回落默认剂量
        if (doseText.isNotEmpty) {
          _timeDoses[newHm] = doseText;
        } else {
          _timeDoses.remove(newHm);
        }
      });
      return null;
    }
    return null; // 取消
  }

  /// 弹窗 hint 用的默认剂量文案
  String get _doseCtrlHint =>
      '${_doseCtrl.text.trim().isEmpty ? '未填' : _doseCtrl.text.trim()} $_unit';

  Future<void> _pickDate({required bool isEnd}) async {
    final DateTime now = DateTime.now();
    final DateTime initial = isEnd
        ? (_endDate ?? now.add(const Duration(days: 6)))
        : (_startDate ?? now);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) && !isEnd ? now : initial,
      firstDate: isEnd ? (_startDate ?? now) : now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 3)),
      helpText: isEnd ? '结束日期' : '开始日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    setState(() {
      if (isEnd) {
        _endDate = picked;
        // 结束日期不能早于开始日期
        if (_startDate != null && picked.isBefore(_startDate!)) {
          _startDate = picked;
        }
      } else {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = null;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  String? get _blockReason {
    if (_nameCtrl.text.trim().isEmpty) return '还差：药品名称';
    final double? v = double.tryParse(_doseCtrl.text.trim());
    if (v == null || v <= 0) return '还差：每次剂量';
    if (_times.isEmpty) return '还差：提醒时间';
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final String? block = _blockReason;
    if (block != null) {
      _toast(block);
      return;
    }

    final double dose = double.parse(_doseCtrl.text.trim());
    final List<String> times = List<String>.from(_times)..sort();

    // 保存前把要保存的完整内容再列一遍：语音录入最容易错的就是剂量
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(_isEdit ? '确认修改' : '确认添加'),
        content: Text(
          '${_nameCtrl.text.trim()}\n'
          '每次 ${_fmtNum(dose)} $_unit\n'
          '${_freqText(times.length)}：${times.join('、')}\n'
          '${_periodText()}',
          style: const TextStyle(
            fontSize: AppText.bodySm,
            height: 1.75,
            color: AppColors.ink,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再改改'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_isEdit ? '保存' : '保存并提醒'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);

    // 每顿独立剂量：与 times 下标对齐；没填独立剂量的位置存默认值
    final List<double>? doseValues = _timeDoses.isEmpty
        ? null
        : <double>[
            for (final String hm in times)
              double.tryParse(_timeDoses[hm] ?? '') ?? dose,
          ];
    // 全部等于默认剂量时没必要存独立剂量，省一层理解成本
    final bool allDefault =
        doseValues == null || doseValues.every((double v) => v == dose);
    // 频次由时间点数量自然表达：1 个 = 每日一次，多个 = 每日多次
    final FrequencyType freq =
        times.length <= 1 ? FrequencyType.once : FrequencyType.multi;

    final Medication med = Medication(
      id: widget.med?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _nameCtrl.text.trim(),
      dosageValue: dose,
      dosageUnit: _unit,
      frequency: freq,
      times: times,
      note: _note,
      startDate: _startDate,
      // null = 长期用药（持续执行，直到手动停用）
      endDate: _endDate,
      enabled: widget.med?.enabled ?? true,
      stoppedAt: widget.med?.stoppedAt,
      createdAt: widget.med?.createdAt ?? DateTime.now(),
      repeat: _repeat,
      weekdays: _repeat == RepeatType.weekly ? _weekdays.toList() : null,
      monthDays: _repeat == RepeatType.monthly ? _monthDays.toList() : null,
      doseValues: allDefault ? null : doseValues,
    );

    await AppState.instance.saveMedication(med);
    await _voice.speak('好了，${med.name} 的提醒已经设置');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// 保存前确认框里的频次文案（读 [_repeat] 与时间点）
  String _freqText(int count) {
    switch (_repeat) {
      case RepeatType.weekly:
        final String days =
            _weekdays.map((int w) => kWeekdayNames[w - 1]).join('、');
        return '每周$days，共 $count 个时间';
      case RepeatType.monthly:
        final List<int> days = _monthDays.toList()..sort();
        return '每月 ${days.join('、')} 日，共 $count 个时间';
      case RepeatType.daily:
        if (count <= 1) return '每天一次';
        const List<String> cn = <String>['零', '一', '二', '三', '四', '五', '六', '七', '八'];
        return '每天${count < cn.length ? cn[count] : '$count'}次';
    }
  }

  String _periodText() {
    final String? s = _startDate == null ? null : _fmtDate(_startDate!);
    final String? e = _endDate == null ? null : _fmtDate(_endDate!);
    if (e == null) return s == null ? '长期服用' : '$s 起，长期服用';
    if (s == null) return '至 $e';
    return '$s ~ $e';
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SimpleNavBar(
              title: _isEdit ? '编辑药品' : '添加药品',
              onBack: () => Navigator.of(context).pop(false),
              trailing: _isEdit
                  ? const SoftBadge(
                      text: '修改后立即生效',
                      foreground: AppColors.muted,
                      background: AppColors.surface,
                    )
                  : null,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.pageX,
                  2,
                  AppSpace.pageX,
                  20,
                ),
                children: <Widget>[
                  if (_listening) _listeningCard(),
                  // 识别结果框：结束收音后出现，文字可改，改完重新填入
                  if (_showResult) _resultCard(),
                  if (!_listening && !_showResult) _voiceEntryCard(),
                  // 没有语音服务时上面那张卡已经把话说清楚了，不再叠一行红字
                  if (_voiceError.isNotEmpty && !_voiceFatal)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              _voiceError,
                              style: const TextStyle(
                                fontSize: AppText.tiny,
                                height: 1.5,
                                color: AppColors.warn,
                              ),
                            ),
                          ),
                          // 麦克风被永久拒绝时，系统不会再有弹窗，只能去设置里手动开
                          if (_micBlocked)
                            TextButton(
                              onPressed: openAppSettings,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                '去打开',
                                style: TextStyle(
                                  fontSize: AppText.tiny,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (_issues.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _issues.first,
                        style: const TextStyle(
                          fontSize: AppText.tiny,
                          height: 1.5,
                          color: AppColors.warn,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const _SectionLabel('基本信息'),
                  const SizedBox(height: 8),
                  AppCard(child: _basicFields()),
                  const SizedBox(height: 16),
                  const _SectionLabel('服药时间与有效期'),
                  const SizedBox(height: 8),
                  AppCard(child: _scheduleFields()),
                  const SizedBox(height: 12),
                  _previewText(),
                ],
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  // --- 语音区 ---------------------------------------------------------------

  Widget _voiceEntryCard() {
    // 这台手机没有语音服务：不再给一个「点了也没反应」的麦克风按钮，
    // 换成一张说明卡 —— 用户最容易犯的错就是对着一台没装语音服务的手机反复说话。
    if (_voiceFatal) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.hairline, width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const AppIconTile(
              AppIcons.micOff,
              tone: AppIconTone.gray,
              size: 34,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '这台手机暂时用不了语音',
                    style: TextStyle(
                      fontSize: AppText.bodySm,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    '系统里没找到语音识别服务。用下面的表单填写一样快，'
                    '药名、剂量、时间填好就能保存。',
                    style: TextStyle(
                      fontSize: AppText.tiny,
                      height: 1.5,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: _startVoice,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(AppIcons.mic, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '点这里开口说一句',
                    style: TextStyle(
                      fontSize: AppText.bodySm,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1B3A8B),
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    '例如「氨氯地平一片，每天早八点，饭后」，识别后可直接改',
                    style: TextStyle(fontSize: AppText.tiny, color: Color(0xFF4A66B0)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.primary),
          ],
        ),
      ),
    );
  }

  Widget _listeningCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.graphic_eq_rounded, size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              // 实时转写：有字了提示「边说边出字」，没字提示「正在听」
              Text(
                _liveText.isEmpty ? '正在听，请说话…' : '正在听，边说边出字',
                style: const TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _stopAndParse,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '说完了',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _cancelVoice,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '取消',
                    style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Waveform(controller: _wave),
          const SizedBox(height: 6),
          // 实时识别文字：已确认的深色 + 正在说的浅色，随说话不断变长
          _liveText.isEmpty
              ? const Text(
                  '……',
                  style: TextStyle(fontSize: AppText.bodySm, color: AppColors.faint),
                )
              : Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      if (_finalBuf.isNotEmpty)
                        TextSpan(
                          text: _finalBuf,
                          style: const TextStyle(
                            fontSize: AppText.bodySm,
                            height: 1.55,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                        ),
                      if (_partial.isNotEmpty)
                        TextSpan(
                          text: _partial,
                          style: TextStyle(
                            fontSize: AppText.bodySm,
                            height: 1.55,
                            fontWeight: FontWeight.w400,
                            color: AppColors.ink.withOpacity(0.55),
                          ),
                        ),
                    ],
                  ),
                ),
        ],
      ),
    );
  }

  /// 识别结果卡：文字可编辑，改完点「重新填入」；不满意可整段重说
  Widget _resultCard() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.edit_note_rounded, size: 18, color: AppColors.sub),
              const SizedBox(width: 6),
              const Text(
                '识别结果（可直接改字）',
                style: TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sub,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _reapplyResult,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '重新填入',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _startVoice,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '重新说',
                    style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _resultCtrl,
            maxLines: 3,
            minLines: 1,
            style: const TextStyle(
              fontSize: AppText.bodySm,
              height: 1.55,
              color: AppColors.ink,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppColors.surface,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.badge),
                borderSide: const BorderSide(color: AppColors.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.badge),
                borderSide: const BorderSide(color: AppColors.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.badge),
                borderSide: const BorderSide(color: AppColors.primary),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '填错了的字直接改，改完点右上角「重新填入」，下面表单会跟着更新。',
            style: TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelVoice() async {
    await _voice.cancel();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _finalBuf = '';
      _partial = '';
      _showResult = false;
    });
  }

  // --- 基本信息 -------------------------------------------------------------

  Widget _basicFields() {
    return Column(
      children: <Widget>[
        FormRow(
          label: '药品名称',
          child: TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: AppText.body, color: AppColors.ink),
            decoration: _dec(
              hint: '例如：氨氯地平（络活喜）',
              flagged: _uncertain.contains('name'),
            ),
          ),
        ),
        const AppDivider(),
        FormRow(
          label: '单次剂量',
          hint: _uncertain.contains('dosage') ? '这一项是从语音推测的，请核对' : null,
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _doseCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: const TextStyle(fontSize: AppText.body, color: AppColors.ink),
                  decoration: _dec(
                    hint: '数量，如 1 或 0.5',
                    flagged: _uncertain.contains('dosage'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.badge),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: kDosageUnits.contains(_unit) ? _unit : '片',
                      isExpanded: true,
                      style: const TextStyle(fontSize: AppText.caption, color: AppColors.ink),
                      items: kDosageUnits
                          .map((String u) => DropdownMenuItem<String>(
                                value: u,
                                child: Text(u),
                              ))
                          .toList(),
                      onChanged: (String? v) {
                        if (v != null) setState(() => _unit = v);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const AppDivider(),
        FormRow(
          label: '服药频次',
          hint: '先选多久吃一次，再在下面添加每次的时间',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // iOS 风格胶囊分段控件：每天 / 每周 / 每月
              SegmentedPills<RepeatType>(
                options: RepeatType.values,
                value: _repeat,
                onChanged: _onRepeatChanged,
                labelOf: (RepeatType r) => r.label,
              ),
              const SizedBox(height: 10),
              // 每周：选星期几（可多选，「每周两次」就是勾两个）
              if (_repeat == RepeatType.weekly) _weekdayPicker(),
              // 每月：选几号（可多选）
              if (_repeat == RepeatType.monthly) _monthDayPicker(),
              const SizedBox(height: 6),
              Text(
                switch (_repeat) {
                  RepeatType.daily => '每天都提醒，时间点在下方增删',
                  RepeatType.weekly => '只在勾选的星期几提醒（至少勾一天）',
                  RepeatType.monthly => '只在勾选的日期提醒；没有 31 号的月份自动按月末算',
                },
                style: const TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
              ),
            ],
          ),
        ),
        const AppDivider(),
        FormRow(
          label: '备注',
          child: GestureDetector(
            onTap: _editNote,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.badge),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _note ?? '未填写（饭前 / 饭后 / 睡前…）',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: _note == null ? AppColors.faint : AppColors.ink,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      size: 18, color: AppColors.faint),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _dec({required String hint, bool flagged = false}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: AppText.caption, color: AppColors.faint),
      isDense: true,
      filled: true,
      fillColor: flagged ? AppColors.warnSoft : AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.badge),
        borderSide: BorderSide(color: flagged ? AppColors.warn : AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.badge),
        borderSide: BorderSide(
          color: flagged ? AppColors.warn.withOpacity(0.5) : AppColors.line,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.badge),
        borderSide: const BorderSide(color: AppColors.primary),
      ),
    );
  }

  Future<void> _editNote() async {
    const List<String> presets = <String>['饭前', '饭后', '随餐', '空腹', '睡前', '晨起'];
    final TextEditingController c =
        TextEditingController(text: _note ?? '');
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('备注'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets
                  .map((String p) => GestureDetector(
                        onTap: () => c.text = p,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(AppRadius.badge),
                          ),
                          child: Text(p,
                              style: const TextStyle(
                                  fontSize: AppText.caption, color: AppColors.sub)),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: c,
              autofocus: true,
              style: const TextStyle(fontSize: AppText.bodySm),
              decoration: const InputDecoration(
                hintText: '也可以自己写，如「早饭前半小时」',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(c.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    c.dispose();
    if (result == null) return;
    setState(() => _note = result.trim().isEmpty ? null : result.trim());
  }

  // --- 时间与有效期 ---------------------------------------------------------

  Widget _scheduleFields() {
    return Column(
      children: <Widget>[
        FormRow(
          label: '提醒时间',
          hint: _times.isEmpty
              ? '至少加一个时间点，保存后才会响'
              : '点某个时间片可以改这一顿的时间或剂量',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String hm in _times)
                    _timeChip(hm),
                  _addTimeChip(),
                ],
              ),
            ],
          ),
        ),
        const AppDivider(),
        FormRow(
          label: '开始日期',
          child: _dateRow(
            value: _startDate == null ? '不限（立即开始）' : _fmtDate(_startDate!),
            onTap: () => _pickDate(isEnd: false),
            onClear: _startDate == null
                ? null
                : () => setState(() => _startDate = null),
          ),
        ),
        const AppDivider(),
        FormRow(
          label: '结束日期',
          hint: _endDate == null
              ? '留空 = 长期服用，持续提醒直到你手动停用'
              : '到了这天之后自动停止提醒，历史记录保留',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _dateRow(
                value: _endDate == null ? '持续执行（长期）' : _fmtDate(_endDate!),
                onTap: () => _pickDate(isEnd: true),
                onClear: _endDate == null ? null : () => setState(() => _endDate = null),
                highlight: _endDate == null,
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _endDate = null),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: <Widget>[
                    Icon(
                      _endDate == null
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: _endDate == null ? AppColors.primary : AppColors.faint,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '长期用药（持续执行）',
                      style: TextStyle(fontSize: AppText.caption, color: AppColors.sub),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 每周几选择器：胶囊多选，样式对齐 iOS 的 FilterChips
  Widget _weekdayPicker() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (int w = 1; w <= 7; w++)
          _toggleChip(
            label: kWeekdayNames[w - 1],
            selected: _weekdays.contains(w),
            onTap: () {
              setState(() {
                if (_weekdays.contains(w)) {
                  // 至少保留一天，全取消等于没设置
                  if (_weekdays.length > 1) _weekdays.remove(w);
                } else {
                  _weekdays.add(w);
                }
              });
            },
          ),
      ],
    );
  }

  /// 每月几号选择器：1-31 胶囊多选
  Widget _monthDayPicker() {
    return Wrap(
      spacing: 6,
      runSpacing: 8,
      children: <Widget>[
        for (int d = 1; d <= 31; d++)
          _toggleChip(
            label: '$d',
            compact: true,
            selected: _monthDays.contains(d),
            onTap: () {
              setState(() {
                if (_monthDays.contains(d)) {
                  if (_monthDays.length > 1) _monthDays.remove(d);
                } else {
                  _monthDays.add(d);
                }
              });
            },
          ),
      ],
    );
  }

  /// iOS 风格的圆角胶囊选择片：选中实底主色，未选中浅灰描边
  Widget _toggleChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool compact = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.line,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? AppText.tiny : AppText.caption,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : AppColors.ink,
          ),
        ),
      ),
    );
  }

  Widget _timeChip(String hm) {
    final String? dose = _timeDoses[hm];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.badge),
        border: Border.all(color: AppColors.primary.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            dose == null ? hm : '$hm · $dose',
            style: const TextStyle(
              fontSize: AppText.caption,
              fontWeight: FontWeight.w600,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            // 点时间片 = 编辑这一顿（时间 + 独立剂量）；长按删除走弹窗里的删除
            onTap: () => _editTime(hm),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.edit_outlined, size: 14, color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addTimeChip() {
    return GestureDetector(
      onTap: _addTime,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.badge),
          border: Border.all(color: AppColors.line),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.add_rounded, size: 14, color: AppColors.sub),
            SizedBox(width: 4),
            Text(
              '加时间',
              style: TextStyle(fontSize: AppText.caption, color: AppColors.sub),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateRow({
    required String value,
    required VoidCallback onTap,
    VoidCallback? onClear,
    bool highlight = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: highlight ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.badge),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: highlight ? FontWeight.w500 : FontWeight.w400,
                  color: highlight ? AppColors.primary : AppColors.ink,
                ),
              ),
            ),
            if (onClear != null)
              GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.close_rounded, size: 16, color: AppColors.faint),
                ),
              ),
            const Icon(Icons.calendar_today_rounded, size: 15, color: AppColors.faint),
          ],
        ),
      ),
    );
  }

  /// 一句话预览：保存前让用户用「人话」再看一遍
  Widget _previewText() {
    final String name = _nameCtrl.text.trim();
    final double? dose = double.tryParse(_doseCtrl.text.trim());
    final StringBuffer b = StringBuffer();
    switch (_repeat) {
      case RepeatType.daily:
        b.write('每天 ');
        break;
      case RepeatType.weekly:
        final List<int> ws = _weekdays.toList()..sort();
        b.write('每${ws.map((int w) => kWeekdayNames[w - 1]).join('、')} ');
        break;
      case RepeatType.monthly:
        final List<int> ds = _monthDays.toList()..sort();
        b.write('每月${ds.join('、')}日 ');
        break;
    }
    b.write(_times.isEmpty ? '（还没选时间）' : _times.join('、'));
    b.write(' 吃 ');
    b.write(name.isEmpty ? '（还没填药名）' : name);
    b.write(' ');
    b.write(dose == null ? '（还没填剂量）' : '${_fmtNum(dose)} $_unit');
    if (_timeDoses.isNotEmpty) {
      final List<String> parts = <String>[
        for (final String hm in _times)
          if (_timeDoses[hm] != null) '$hm ${_timeDoses[hm]} $_unit',
      ];
      if (parts.isNotEmpty) b.write('（其中 ${parts.join('、')}）');
    }
    if (_note != null) b.write('，$_note');
    b.write('；${_endDate == null ? '长期服用' : '${_fmtDate(_endDate!)} 停止'}。');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        b.toString(),
        style: const TextStyle(
          fontSize: AppText.caption,
          height: 1.65,
          color: AppColors.muted,
        ),
      ),
    );
  }

  // --- 底部 -----------------------------------------------------------------

  Widget _footer() {
    final String? block = _blockReason;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: Column(
        children: <Widget>[
          PrimaryButton(
            label: block ?? (_isEdit ? '保存修改' : '保存并开启提醒'),
            enabled: block == null && !_saving,
            onPressed: _save,
          ),
          if (_isEdit) ...<Widget>[
            const SizedBox(height: 10),
            TextButton(
              onPressed: _saving ? null : _deleteFromEdit,
              child: const Text(
                '删除这个药品',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteFromEdit() async {
    final Medication? m = widget.med;
    if (m == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除「${m.name}」'),
        content: const Text(
          '删除后不再提醒，历史服药记录也会一起清掉，无法恢复。\n\n'
          '只是不想再吃的话，回列表点「停止提醒」更合适。',
          style: TextStyle(fontSize: AppText.caption, height: 1.7, color: AppColors.sub),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppState.instance.deleteMedication(m);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _toast(String text) {
    showAppToast(context, text);
  }

  // --- 工具 -----------------------------------------------------------------

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static TimeOfDay _parseHm(String hm) {
    final List<String> p = hm.split(':');
    return TimeOfDay(
      hour: int.tryParse(p[0]) ?? 8,
      minute: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0,
    );
  }
}

/// 小标题
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: AppText.caption,
        fontWeight: FontWeight.w600,
        color: AppColors.sub,
      ),
    );
  }
}

/// 说话时的波形：只是动画，不代表真实音量
class _Waveform extends AnimatedWidget {
  const _Waveform({required AnimationController controller})
      : super(listenable: controller);

  @override
  Widget build(BuildContext context) {
    final double t = (listenable as AnimationController).value;
    return SizedBox(
      height: 30,
      width: 150,
      child: CustomPaint(painter: _WavePainter(t: t)),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = AppColors.primary
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;

    const int bars = 15;
    final double step = size.width / (bars - 1);
    for (int i = 0; i < bars; i++) {
      final double phase = t * 2 * math.pi + i * 0.6;
      final double amp = (math.sin(phase) + 1) / 2;
      final double h = 5 + amp * 22;
      final double x = i * step;
      canvas.drawLine(
        Offset(x, size.height / 2 - h / 2),
        Offset(x, size.height / 2 + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.t != t;
}
