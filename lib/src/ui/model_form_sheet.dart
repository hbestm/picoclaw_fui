import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:remixicon/remixicon.dart';

import '../core/core_api_client.dart';
import 'widgets/bilingual_text.dart';

/// 添加 / 编辑模型的底部表单。
class ModelFormSheet extends StatefulWidget {
  final CoreApiClient client;
  final List<ProviderOption> providers;
  final CoreModel? existing;

  const ModelFormSheet({
    super.key,
    required this.client,
    required this.providers,
    this.existing,
  });

  @override
  State<ModelFormSheet> createState() => _ModelFormSheetState();
}

class _ModelFormSheetState extends State<ModelFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _modelId;
  late final TextEditingController _apiBase;
  late final TextEditingController _apiKey;
  String? _provider;
  bool _keyObscure = true;
  bool _saving = false;
  bool _testing = false;
  bool _fetching = false;
  TestResult? _testResult;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _modelId = TextEditingController(text: e?.model ?? '');
    _apiBase = TextEditingController(text: e?.apiBase ?? '');
    _apiKey = TextEditingController();
    final creatable =
        widget.providers.where((p) => p.createAllowed).toList();
    if (e != null && e.provider.isNotEmpty) {
      _provider = e.provider;
    } else if (creatable.isNotEmpty) {
      // 默认给一个 OpenAI 兼容入口
      final openai = creatable.where(
        (p) => p.id == 'openai' || p.id == 'openai-compatible',
      );
      _provider = (openai.isNotEmpty ? openai.first : creatable.first).id;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _modelId.dispose();
    _apiBase.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  List<ProviderOption> get _creatable =>
      widget.providers.where((p) => p.createAllowed).toList();

  Future<void> _test() async {
    if (_provider == null || _provider!.isEmpty) return;
    final model = _modelId.text.trim();
    if (model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, '请先填写模型 ID', 'Enter the model ID first')),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final r = await widget.client.testInline(
        provider: _provider!,
        model: model,
        apiBase: _apiBase.text.trim(),
        apiKey: _apiKey.text,
        modelIndex: _isEdit ? widget.existing!.index : null,
      );
      if (mounted) setState(() => _testResult = r);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _fetchModels() async {
    if (_provider == null || _provider!.isEmpty) return;
    setState(() => _fetching = true);
    try {
      final ids = await widget.client.fetchProviderModels(
        provider: _provider!,
        apiBase: _apiBase.text.trim(),
        apiKey: _apiKey.text,
        modelIndex: _isEdit ? widget.existing!.index : null,
      );
      if (!mounted) return;
      if (ids.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, '没有拉取到模型', 'No models fetched')),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      final picked = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(tr(c, '选择模型', 'Pick a model')),
          children: [
            for (final id in ids.take(100))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, id),
                child: Text(id, style: const TextStyle(fontSize: 14)),
              ),
          ],
        ),
      );
      if (picked != null && mounted) {
        setState(() => _modelId.text = picked);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            context, '拉取失败：$e', 'Fetch failed: $e')),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_provider == null || _provider!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, '请选择提供商', 'Pick a provider')),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'model_name': _name.text.trim(),
      'provider': _provider,
      'model': _modelId.text.trim(),
      'enabled': true,
    };
    final base = _apiBase.text.trim();
    if (base.isNotEmpty) body['api_base'] = base;
    final key = _apiKey.text;
    if (key.isNotEmpty) body['api_key'] = key;
    try {
      if (_isEdit) {
        await widget.client.updateModel(widget.existing!.index, body);
      } else {
        await widget.client.addModel(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, '保存失败：$e', 'Save failed: $e')),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final creatable = _creatable;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withAlpha(60),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isEdit
                    ? tr(context, '编辑模型', 'Edit model')
                    : tr(context, '添加模型', 'Add model'),
                style: GoogleFonts.inter(
                    fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: tr(context, '显示名称', 'Display name'),
                  hintText: tr(context, '例如：我的 GPT', 'e.g. My GPT'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Remix.tag_line),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? tr(context, '必填', 'Required')
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _provider,
                decoration: InputDecoration(
                  labelText: tr(context, '提供商', 'Provider'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Remix.plug_line),
                ),
                items: [
                  for (final p in creatable)
                    DropdownMenuItem(value: p.id, child: Text(p.label)),
                  if (_provider != null &&
                      !creatable.any((p) => p.id == _provider))
                    DropdownMenuItem(
                        value: _provider, child: Text(_provider!)),
                ],
                onChanged: (v) => setState(() {
                  _provider = v;
                  _testResult = null;
                }),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _modelId,
                      decoration: InputDecoration(
                        labelText: tr(context, '模型 ID', 'Model ID'),
                        hintText: 'gpt-4o-mini',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Remix.cpu_line),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? tr(context, '必填', 'Required')
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: tr(context, '拉取可用模型', 'Fetch available models'),
                    onPressed: _fetching ? null : _fetchModels,
                    icon: _fetching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Remix.download_cloud_2_line),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiBase,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText:
                      tr(context, '接口地址（可选）', 'API base URL (optional)'),
                  hintText: 'https://api.example.com/v1',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Remix.link_m),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiKey,
                obscureText: _keyObscure,
                decoration: InputDecoration(
                  labelText: _isEdit
                      ? tr(context, 'API Key（留空则保留原密钥）',
                          'API key (blank keeps existing)')
                      : tr(context, 'API Key', 'API key'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Remix.key_2_line),
                  suffixIcon: IconButton(
                    icon: Icon(_keyObscure
                        ? Remix.eye_off_line
                        : Remix.eye_line),
                    onPressed: () =>
                        setState(() => _keyObscure = !_keyObscure),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildTestRow(cs),
              const SizedBox(height: 16),
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Remix.check_line),
                  label: Text(_isEdit
                      ? tr(context, '保存', 'Save')
                      : tr(context, '添加', 'Add')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTestRow(ColorScheme cs) {
    final r = _testResult;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: r == null
                ? Text(
                    tr(context, '保存前可以先测试连通性', 'Test connectivity before saving'),
                    style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withAlpha(140)),
                  )
                : Row(
                    children: [
                      Icon(
                        r.success
                            ? Remix.checkbox_circle_fill
                            : Remix.close_circle_fill,
                        size: 18,
                        color: r.success ? Colors.green : cs.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          r.success
                              ? tr(context, '连接成功 · ${r.latencyMs}ms',
                                  'Connected · ${r.latencyMs}ms')
                              : tr(context, '连接失败：${r.error}',
                                  'Failed: ${r.error}'),
                          style: TextStyle(
                            fontSize: 13,
                            color: r.success ? Colors.green : cs.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Remix.wifi_line, size: 16),
            label: Text(tr(context, '测试', 'Test')),
          ),
        ],
      ),
    );
  }
}
