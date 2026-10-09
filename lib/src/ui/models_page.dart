import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:remixicon/remixicon.dart';

import '../core/core_api_client.dart';
import '../core/service_manager.dart';
import 'model_form_sheet.dart';
import 'widgets/bilingual_text.dart';

/// 原生模型管理页：列表 / 添加 / 编辑 / 删除 / 设为默认 / 连通性测试。
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

enum _Gate { loading, login, setup, ready, error }

class _ModelsPageState extends State<ModelsPage> {
  CoreApiClient? _client;
  _Gate _gate = _Gate.loading;
  String _gateError = '';
  ModelsData? _data;
  bool _loadingModels = false;

  final _pwController = TextEditingController();
  bool _pwObscure = true;
  bool _authBusy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _pwController.dispose();
    _client?.close();
    super.dispose();
  }

  void _init() {
    final service = context.read<ServiceManager>();
    _client = CoreApiClient(service.webUrl);
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    setState(() {
      _gate = _Gate.loading;
      _gateError = '';
    });
    try {
      final st = await _client!.authStatus();
      if (!mounted) return;
      if (st['authenticated'] == true) {
        setState(() => _gate = _Gate.ready);
        _loadModels();
      } else if (st['initialized'] == true) {
        setState(() => _gate = _Gate.login);
      } else {
        setState(() => _gate = _Gate.setup);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gate = _Gate.error;
        _gateError = e.toString();
      });
    }
  }

  Future<void> _submitPassword() async {
    final pw = _pwController.text;
    if (pw.isEmpty) return;
    setState(() => _authBusy = true);
    try {
      if (_gate == _Gate.setup) {
        await _client!.setupPassword(pw);
      } else {
        await _client!.login(pw);
      }
      if (!mounted) return;
      _pwController.clear();
      setState(() => _gate = _Gate.ready);
      _loadModels();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, '验证失败：$e', 'Auth failed: $e')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _authBusy = false);
    }
  }

  Future<void> _loadModels() async {
    setState(() => _loadingModels = true);
    try {
      final data = await _client!.getModels();
      if (!mounted) return;
      setState(() => _data = data);
    } on CoreApiAuthException {
      if (mounted) setState(() => _gate = _Gate.login);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, '加载失败：$e', 'Load failed: $e')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _openForm({CoreModel? existing}) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ModelFormSheet(
        client: _client!,
        providers: _data?.providers ?? const [],
        existing: existing,
      ),
    );
    if (changed == true) _loadModels();
  }

  Future<void> _deleteModel(CoreModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, '删除模型', 'Delete model')),
        content: Text(
          tr(context, '确定删除「${m.name}」吗？此操作不可撤销。',
              'Delete "${m.name}"? This cannot be undone.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr(context, '取消', 'Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr(context, '删除', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _client!.deleteModel(m.index);
      _loadModels();
    } on CoreApiAuthException {
      if (mounted) setState(() => _gate = _Gate.login);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _setDefault(CoreModel m) async {
    try {
      await _client!.setDefaultModel(m.name);
      _loadModels();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              tr(context, '已设为默认模型', 'Set as default model')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on CoreApiAuthException {
      if (mounted) setState(() => _gate = _Gate.login);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr(context, '模型', 'Models'),
          style: GoogleFonts.inter(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_gate == _Gate.ready)
            IconButton(
              tooltip: tr(context, '刷新', 'Refresh'),
              icon: const Icon(Remix.refresh_line),
              onPressed: _loadingModels ? null : _loadModels,
            ),
        ],
      ),
      floatingActionButton: _gate == _Gate.ready
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Remix.add_line),
              label: Text(tr(context, '添加模型', 'Add model')),
            )
          : null,
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    switch (_gate) {
      case _Gate.loading:
        return const Center(child: CircularProgressIndicator());
      case _Gate.login:
      case _Gate.setup:
        return _buildAuthGate(colorScheme);
      case _Gate.error:
        return _buildError(colorScheme);
      case _Gate.ready:
        return _buildList(colorScheme);
    }
  }

  Widget _buildError(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Remix.error_warning_line,
                size: 48, color: colorScheme.error.withAlpha(180)),
            const SizedBox(height: 16),
            Text(
              tr(context, '无法连接 Core 服务', 'Cannot reach Core service'),
              style: GoogleFonts.inter(
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _gateError,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: colorScheme.onSurface.withAlpha(150), fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _checkAuth,
              icon: const Icon(Remix.refresh_line),
              label: Text(tr(context, '重试', 'Retry')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthGate(ColorScheme colorScheme) {
    final isSetup = _gate == _Gate.setup;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colorScheme.secondary.withAlpha(25),
                  shape: BoxShape.circle,
                ),
                child: Icon(Remix.lock_line,
                    size: 40, color: colorScheme.secondary),
              ),
              const SizedBox(height: 24),
              Text(
                isSetup
                    ? tr(context, '设置控制台密码', 'Set dashboard password')
                    : tr(context, '需要验证', 'Authentication required'),
                style: GoogleFonts.inter(
                    fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                isSetup
                    ? tr(context, '首次使用请设置控制台密码，用于保护模型配置。',
                        'Set a dashboard password to protect model config.')
                    : tr(context, '请输入控制台密码以管理模型。',
                        'Enter the dashboard password to manage models.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: colorScheme.onSurface.withAlpha(160), fontSize: 14),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _pwController,
                obscureText: _pwObscure,
                autofocus: true,
                onSubmitted: (_) => _submitPassword(),
                decoration: InputDecoration(
                  labelText: tr(context, '密码', 'Password'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Remix.key_2_line),
                  suffixIcon: IconButton(
                    icon: Icon(_pwObscure
                        ? Remix.eye_off_line
                        : Remix.eye_line),
                    onPressed: () =>
                        setState(() => _pwObscure = !_pwObscure),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _authBusy ? null : _submitPassword,
                  child: _authBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(isSetup
                          ? tr(context, '设置并继续', 'Set & continue')
                          : tr(context, '登录', 'Sign in')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(ColorScheme colorScheme) {
    final models = _data?.models ?? [];
    if (_loadingModels && models.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (models.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Remix.cpu_line,
                  size: 56,
                  color: colorScheme.onSurface.withAlpha(100)),
              const SizedBox(height: 16),
              Text(
                tr(context, '还没有模型', 'No models yet'),
                style: GoogleFonts.inter(
                    fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                tr(context, '点击右下角按钮添加第一个模型。',
                    'Tap the button below to add your first model.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: colorScheme.onSurface.withAlpha(150)),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadModels,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: models.length,
        itemBuilder: (_, i) => _ModelCard(
          model: models[i],
          onEdit: () => _openForm(existing: models[i]),
          onDelete: () => _deleteModel(models[i]),
          onSetDefault: () => _setDefault(models[i]),
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final CoreModel model;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSetDefault;

  const _ModelCard({
    required this.model,
    required this.onEdit,
    required this.onDelete,
    required this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusColor = model.available
        ? Colors.green
        : (model.status.isNotEmpty ? Colors.orange : cs.onSurface.withAlpha(120));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withAlpha(120)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      model.name,
                      style: GoogleFonts.inter(
                          fontSize: 16, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (model.isDefault)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: cs.secondary.withAlpha(30),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        tr(context, '默认', 'Default'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: cs.secondary,
                        ),
                      ),
                    ),
                  PopupMenuButton<String>(
                    icon: const Icon(Remix.more_2_fill, size: 20),
                    onSelected: (v) {
                      if (v == 'edit') onEdit();
                      if (v == 'default') onSetDefault();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (c) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(tr(c, '编辑', 'Edit')),
                      ),
                      if (!model.isDefault)
                        PopupMenuItem(
                          value: 'default',
                          child: Text(tr(c, '设为默认', 'Set as default')),
                        ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          tr(c, '删除', 'Delete'),
                          style: TextStyle(color: cs.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(context, model.provider.isEmpty ? '?' : model.provider,
                      cs.secondary),
                  _chip(context, model.model, cs.onSurface.withAlpha(160)),
                ],
              ),
              if (model.apiBase.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Remix.link_m,
                        size: 13, color: cs.onSurface.withAlpha(120)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        model.apiBase,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withAlpha(140),
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              if (model.status.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  model.available
                      ? tr(context, '可用', 'Available')
                      : tr(context, '状态：${model.status}', 'Status: ${model.status}'),
                  style: TextStyle(fontSize: 12, color: statusColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
