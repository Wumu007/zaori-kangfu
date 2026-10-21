import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/medication.dart';
import '../models/medication_draft.dart';
import '../services/medication_nlu.dart';
import '../services/voice_input_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

/// 语音录入页（两态：聆听 → 确认）
///
/// 四个不能省的设计约束（都是防「吃错药」，不是防「不好看」）：
/// 1. **点按开始/结束**，不用长按 —— 手抖容易松开；
/// 2. **拆成 4 行分项确认**，不是整句确认 —— 一处听错只需重说这一处；
/// 3. **剂量没听清就留空并禁用保存** —— 绝不给默认剂量；
/// 4. **保存前 TTS 回读 + 二次确认** —— 最后一道闸。
class VoiceIntakePage extends StatefulWidget {
  const VoiceIntakePage({super.key});

  @override
  State<VoiceIntakePage> createState() => _VoiceIntakePageState();
}

enum _Stage { listening, confirm }

class _VoiceIntakePageState extends State<VoiceIntakePage>
    with SingleTickerProviderStateMixin {
  final VoiceInputService _voice = VoiceInputService();

  late final AnimationController _wave =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  _Stage _stage = _Stage.listening;
  String _partial = '';
  String _error = '';
  MedicationDraft? _draft;
  bool _saving = false;

  /// 非空 = 正在「只重说这一个字段」
  String? _retarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _wave.dispose();
    _voice.dispose();
    super.dispose();
  }

  // --- 收音 -----------------------------------------------------------------

  Future<void> _start({String? field}) async {
    setState(() {
      _stage = _Stage.listening;
      _partial = '';
      _error = '';
      _retarget = field;
    });

    final bool ok = await _voice.ensureReady();
    if (!ok && mounted) {
      setState(() {
        _error = '麦克风或语音识别不可用，可以先用键盘输入';
        _stage = _Stage.confirm;
        _draft = MedicationDraft(rawText: '');
      });
      return;
    }

    await _voice.start(
      onPartial: (String t) {
        if (!mounted) return;
        setState(() => _partial = t);
      },
      onFinal: (String t) {
        if (!mounted) return;
        _handleText(t);
      },
      onError: (String msg) {
        if (!mounted) return;
        setState(() => _error = msg);
      },
    );
  }

  Future<void> _stopAndParse() async {
    await _voice.stop();
    if (!mounted) return;
    final String text = _partial.trim();
    if (text.isEmpty) {
      setState(() => _error = '没听到声音，再说一次好吗？');
      return;
    }
    _handleText(text);
  }

  /// 识别结果 → 草稿
  void _handleText(String text) {
    final MedicationDraft parsed = MedicationNlu.parse(text);

    // 整句重新说
    if (_retarget == null || _draft == null) {
      setState(() {
        _draft = parsed;
        _partial = text;
        _stage = _Stage.confirm;
        _retarget = null;
      });
      // 缺什么就直接念出来，别让用户自己找
      _voice.speak(parsed.issues.isNotEmpty ? parsed.issues.first : parsed.readBackText);
      return;
    }

    // 只重说某一个字段：其余字段原样保留
    final MedicationDraft base = _draft!;
    setState(() {
      switch (_retarget) {
        case 'name':
          base.name = text.trim();
          base.fieldConfidence['name'] = 0.95;
          base.uncertainFields.remove('name');
          break;
        case 'dosage':
          if (parsed.dosageValue != null && parsed.dosageUnit != null) {
            base.dosageValue = parsed.dosageValue;
            base.dosageUnit = parsed.dosageUnit;
            base.fieldConfidence['dosage'] = 0.95;
            base.uncertainFields.remove('dosage');
            base.issues.removeWhere((String e) => e.contains('剂量'));
          }
          break;
        case 'times':
          if (parsed.times.isNotEmpty) {
            base.times
              ..clear()
              ..addAll(parsed.times);
            base.fieldConfidence['times'] = 0.95;
            base.uncertainFields.remove('times');
            base.issues.removeWhere((String e) => e.contains('时间') || e.contains('钟点'));
          }
          break;
        case 'note':
          base.timingNote = parsed.timingNote ?? text.trim();
          break;
      }
      _retarget = null;
      _stage = _Stage.confirm;
    });
    _voice.speakBack(base);
  }

  // --- 保存 -----------------------------------------------------------------

  Future<void> _save() async {
    final MedicationDraft? d = _draft;
    if (d == null || !d.readyToSave || _saving) return;

    setState(() => _saving = true);
    final Medication med = d.toMedication();

    // 二次确认：把要保存的完整内容再念一遍，用户点「保存」才算数
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('确认保存'),
        content: Text(
          '${med.name}\n每次 ${med.dosageText}'
          '${med.note == null ? '' : '，${med.note}'}\n'
          '每天 ${med.times.length} 次：${med.times.join('、')}',
          style: const TextStyle(
            fontSize: AppText.bodySm,
            height: 1.7,
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
            child: const Text('保存并提醒'),
          ),
        ],
      ),
    );

    if (ok != true) {
      if (mounted) setState(() => _saving = false);
      return;
    }

    await AppState.instance.saveMedication(med);
    await _voice.speak('好了，${med.name} 的提醒已经设置');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // --- 手改 -----------------------------------------------------------------

  Future<void> _editName() async {
    final MedicationDraft d = _draft!;
    final String? name = await _askText(
      title: '药品名称',
      initial: d.name ?? '',
      hint: '例如：氨氯地平',
    );
    if (name == null || name.trim().isEmpty) return;
    setState(() {
      d.name = name.trim();
      d.fieldConfidence['name'] = 0.95;
      d.uncertainFields.remove('name');
    });
  }

  Future<void> _editDosage() async {
    final MedicationDraft d = _draft!;
    final _DoseResult? result = await showDialog<_DoseResult>(
      context: context,
      builder: (BuildContext ctx) => _DosageDialog(
        initialValue: d.dosageValue,
        initialUnit: d.dosageUnit ?? '片',
      ),
    );
    if (result == null) return;

    setState(() {
      d.dosageValue = result.value;
      d.dosageUnit = result.unit;
      d.fieldConfidence['dosage'] = 0.95;
      d.uncertainFields.remove('dosage');
      d.issues.removeWhere((String e) => e.contains('剂量'));
    });
  }

  Future<void> _editTimes() async {
    final MedicationDraft d = _draft!;
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null) return;
    final String hm = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (d.times.contains(hm)) {
        d.times.remove(hm);
      } else {
        d.times.add(hm);
        d.times.sort();
      }
      if (d.times.isNotEmpty) {
        d.fieldConfidence['times'] = 0.9;
        d.uncertainFields.remove('times');
      }
    });
  }

  Future<void> _editNote() async {
    final MedicationDraft d = _draft!;
    final String? note = await _askText(
      title: '备注',
      initial: d.timingNote ?? '',
      hint: '饭前 / 饭后 / 随餐 / 睡前',
    );
    if (note == null) return;
    setState(() => d.timingNote = note.trim().isEmpty ? null : note.trim());
  }

  Future<String?> _askText({
    required String title,
    required String initial,
    required String hint,
  }) async {
    final TextEditingController c = TextEditingController(text: initial);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(fontSize: AppText.bodySm),
          decoration: InputDecoration(hintText: hint),
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
    return result;
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _nav(),
            Expanded(
              child: _stage == _Stage.listening
                  ? _listeningBody()
                  : _confirmBody(),
            ),
            _stage == _Stage.listening ? _listeningFooter() : _confirmFooter(),
          ],
        ),
      ),
    );
  }

  Widget _nav() => SimpleNavBar(
        title: _stage == _Stage.listening ? '语音录入' : '确认用药信息',
        leadingIcon: _stage == _Stage.listening
            ? Icons.close_rounded
            : Icons.arrow_back_ios_new_rounded,
        onBack: () {
          if (_stage == _Stage.listening) {
            _voice.cancel();
            Navigator.of(context).pop(false);
          } else {
            setState(() => _stage = _Stage.listening);
            _start();
          }
        },
      );

  // 聆听态 -------------------------------------------------------------------

  Widget _listeningBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Text(
            '说出药名、剂量和时间，一句就够',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
          ),
          const SizedBox(height: 26),
          GestureDetector(
            onTap: _stopAndParse,
            child: Container(
              width: 120,
              height: 120,
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic_none_rounded, size: 34, color: Colors.white),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          // 波形：让用户确认「它在听」，而不是对着黑屏说话
          _Waveform(controller: _wave, active: _error.isEmpty),
          const SizedBox(height: 22),
          _transcriptCard(),
          if (_error.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: AppText.caption, color: AppColors.warn),
            ),
          ],
        ],
      ),
    );
  }

  Widget _transcriptCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '正在转写',
            style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          Text(
            _partial.isEmpty ? '……' : '$_partial|',
            style: const TextStyle(
              fontSize: AppText.h2,
              height: 1.6,
              fontWeight: FontWeight.w500,
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _listeningFooter() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          children: <Widget>[
            PrimaryButton(label: '说完了', onPressed: _stopAndParse),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                _voice.cancel();
                Navigator.of(context).pop(false);
              },
              child: const Text(
                '取消',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
              ),
            ),
          ],
        ),
      );

  // 确认态 -------------------------------------------------------------------

  Widget _confirmBody() {
    final MedicationDraft d = _draft!;
    final bool missingDosage = !d.hasDosage;

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 4, AppSpace.pageX, 16),
      children: <Widget>[
        Text(
          d.rawText.isEmpty ? '没有语音，请手动填写' : '你说的：「${d.rawText}」',
          style: const TextStyle(
            fontSize: AppText.caption,
            height: 1.5,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 12),
        AppCard(
          child: Column(
            children: <Widget>[
              _ConfirmRow(
                label: '药名',
                value: d.name ?? '没听清',
                uncertain: !d.hasName || d.uncertainFields.contains('name'),
                onRetell: () => _start(field: 'name'),
                onEdit: _editName,
                onTapValue: _editName,
              ),
              const AppDivider(),
              _ConfirmRow(
                label: '剂量',
                value: d.hasDosage ? '${_num(d.dosageValue!)} ${d.dosageUnit}' : '没听清',
                uncertain: missingDosage || d.uncertainFields.contains('dosage'),
                // 剂量是安全红线：空着就明说，不给默认值
                hint: missingDosage ? '必须补上，不能猜' : null,
                onRetell: () => _start(field: 'dosage'),
                onEdit: _editDosage,
                onTapValue: _editDosage,
              ),
              const AppDivider(),
              _ConfirmRow(
                label: '时间',
                value: d.times.isEmpty ? '没听清' : d.times.join(' · '),
                uncertain: d.times.isEmpty || d.uncertainFields.contains('times'),
                hint: d.uncertainFields.contains('times')
                    ? '「${d.periodHint ?? '时段'}」已按上面的钟点理解，对吗？'
                    : null,
                onRetell: () => _start(field: 'times'),
                onEdit: _editTimes,
                onTapValue: _editTimes,
              ),
              const AppDivider(),
              _ConfirmRow(
                label: '备注',
                value: (d.timingNote == null || d.timingNote!.isEmpty)
                    ? '未填写'
                    : d.timingNote!,
                uncertain: false,
                onRetell: () => _start(field: 'note'),
                onEdit: _editNote,
                onTapValue: _editNote,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (d.issues.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              d.issues.first,
              style: const TextStyle(
                fontSize: AppText.tiny,
                height: 1.5,
                color: AppColors.warn,
              ),
            ),
          ),
        const Row(
          children: <Widget>[
            Icon(Icons.volume_up_outlined, size: 16, color: AppColors.muted),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                '正在为你读一遍，听一听对不对',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _confirmFooter() {
    final MedicationDraft d = _draft!;
    final List<String> missing = <String>[
      if (!d.hasName) '药名',
      if (!d.hasDosage) '剂量',
      if (!d.hasTimes) '时间',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        children: <Widget>[
          PrimaryButton(
            label: missing.isEmpty ? '保存并开启提醒' : '还差：${missing.join('、')}',
            enabled: missing.isEmpty,
            onPressed: _save,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => _start(),
            child: const Text(
              '整句再说一遍',
              style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

/// 4 行确认卡里的一行
class _ConfirmRow extends StatelessWidget {
  const _ConfirmRow({
    required this.label,
    required this.value,
    required this.uncertain,
    required this.onRetell,
    required this.onEdit,
    required this.onTapValue,
    this.hint,
  });

  final String label;
  final String value;

  /// true = 低置信度/缺失，整行标黄并要求用户处理
  final bool uncertain;
  final VoidCallback onRetell;
  final VoidCallback onEdit;
  final VoidCallback onTapValue;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(fontSize: AppText.caption, color: AppColors.muted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                GestureDetector(
                  onTap: onTapValue,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w500,
                      color: uncertain ? AppColors.warn : AppColors.ink,
                    ),
                  ),
                ),
                if (hint != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.warnSoft,
                      borderRadius: BorderRadius.circular(AppRadius.badge),
                    ),
                    child: Text(
                      hint!,
                      style: const TextStyle(fontSize: AppText.tiny, color: AppColors.warn),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 单项重说：只重讲这一项，不用整句重来
          InkWell(
            onTap: onRetell,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                '重说',
                style: TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
          InkWell(
            onTap: onEdit,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Icon(Icons.edit_outlined, size: 16, color: AppColors.faint),
            ),
          ),
        ],
      ),
    );
  }
}

/// 说话时的波形：只是动画，不代表真实音量
class _Waveform extends AnimatedWidget {
  const _Waveform({required AnimationController controller, required this.active})
      : super(listenable: controller);

  final bool active;

  @override
  Widget build(BuildContext context) {
    final double t = (listenable as AnimationController).value;
    return SizedBox(
      height: 40,
      width: 171,
      child: CustomPaint(painter: _WavePainter(t: t, active: active)),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.t, required this.active});

  final double t;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = active ? AppColors.primary : AppColors.faint
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;

    const int bars = 15;
    final double step = size.width / (bars - 1);
    for (int i = 0; i < bars; i++) {
      final double phase = t * 2 * math.pi + i * 0.6;
      final double amp = (math.sin(phase) + 1) / 2; // 0~1
      final double h = 6 + amp * 30;
      final double x = i * step;
      canvas.drawLine(
        Offset(x, size.height / 2 - h / 2),
        Offset(x, size.height / 2 + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.t != t || old.active != active;
}

/// 剂量编辑结果
class _DoseResult {
  const _DoseResult(this.value, this.unit);
  final double value;
  final String unit;
}

/// 剂量编辑弹窗
///
/// 单独做成 StatefulWidget 是因为「单位下拉」必须能刷新自己 ——
/// 用闭包变量改值在弹窗里是不会重绘的，会变成选了没反应的假交互。
class _DosageDialog extends StatefulWidget {
  const _DosageDialog({this.initialValue, required this.initialUnit});

  final double? initialValue;
  final String initialUnit;

  @override
  State<_DosageDialog> createState() => _DosageDialogState();
}

class _DosageDialogState extends State<_DosageDialog> {
  static const List<String> _units = <String>['片', '粒', '袋', 'ml', 'mg', '滴'];

  late final TextEditingController _value = TextEditingController(
    text: widget.initialValue == null ? '' : _fmt(widget.initialValue!),
  );
  late String _unit = _units.contains(widget.initialUnit) ? widget.initialUnit : '片';
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  void _submit() {
    final double? v = double.tryParse(_value.text.trim());
    if (v == null || v <= 0) {
      setState(() => _error = '请填一个大于 0 的数字');
      return;
    }
    Navigator.of(context).pop(_DoseResult(v, _unit));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('每次剂量'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _value,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: AppText.bodySm),
                  decoration: const InputDecoration(
                    hintText: '数量，如 1 或 0.5',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: _unit,
                items: _units
                    .map((String u) => DropdownMenuItem<String>(
                          value: u,
                          child: Text(u, style: const TextStyle(fontSize: AppText.bodySm)),
                        ))
                    .toList(),
                onChanged: (String? v) => setState(() => _unit = v ?? _unit),
              ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(fontSize: AppText.tiny, color: AppColors.warn),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
