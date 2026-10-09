import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:remixicon/remixicon.dart';

import '../core/core_api_client.dart';
import 'model_form_sheet.dart';
import 'widgets/bilingual_text.dart';
import 'widgets/core_auth_gate.dart';

/// 原生模型管理页：列表 / 添加 / 编辑 / 删除 / 设为默认 / 连通性测试。
class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CoreAuthGate(
      builder: (context, client) => _ModelsView(client: client),
    );
  }
}

enum _Filter { all, available, unconfigured }

class _ModelsView extends StatefulWidget {
  final CoreApiClient client;
  const _ModelsView({required this.client});

  @override
  State<_ModelsView> createState() => _ModelsViewState();
}

class _ModelsViewState extends State<_ModelsView> {
  ModelsData? _data;
  bool _loading = false;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    setState(() => _loading = true);
    try {
      final data = await widget.client.getModels();
      if (!mounted) return;
      setState(() => _data = data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, '加载失败：$e', 'Load failed: $e')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CoreModel> get _filtered {
    final models = _data?.models ?? [];
    switch (_filter) {
      case _Filter.available:
        return models.where((m) => m.available).toList();
      case _Filter.unconfigured:
        return models.where((m) => !m.available).toList();
      case _Filter.all:
        // 可用的排前面
        return [...models]
          ..sort((a, b) => (b.available ? 1 : 0) - (a.available ? 1 : 0));
    }
  }

  Future<void> _openForm({CoreModel? existing}) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ModelFormSheet(
        client: widget.client,
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
      await widget.client.deleteModel(m.index);
      _loadModels();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _setDefault(CoreModel m) async {
    try {
      await widget.client.setDefaultModel(m.name);
      _loadModels();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(tr(context, '已设为默认模型', 'Set as default model')),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
          IconButton(
            tooltip: tr(context, '刷新', 'Refresh'),
            icon: const Icon(Remix.refresh_line),
            onPressed: _loading ? null : _loadModels,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Remix.add_line),
        label: Text(tr(context, '添加模型', 'Add model')),
      ),
      body: Column(
        children: [
          _buildFilterBar(colorScheme),
          Expanded(child: _buildList(colorScheme)),
        ],
      ),
    );
  }

  Widget _buildFilterBar(ColorScheme cs) {
    final models = _data?.models ?? [];
    final availableCount = models.where((m) => m.available).length;
    final unconfiguredCount = models.length - availableCount;
    Widget chip(_Filter f, String label, int count) {
      final selected = _filter == f;
      return ChoiceChip(
        label: Text('$label · $count'),
        selected: selected,
        onSelected: (_) => setState(() => _filter = f),
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? cs.onSecondary : cs.onSurface.withAlpha(180),
        ),
        selectedColor: cs.secondary,
        backgroundColor: cs.surfaceContainerHighest.withAlpha(120),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          chip(_Filter.all, tr(context, '全部', 'All'), models.length),
          const SizedBox(width: 8),
          chip(_Filter.available, tr(context, '可用', 'Available'),
              availableCount),
          const SizedBox(width: 8),
          chip(_Filter.unconfigured, tr(context, '未配置', 'Unconfigured'),
              unconfiguredCount),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme colorScheme) {
    final models = _filtered;
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (models.isEmpty) {
      final isFiltering = _filter != _Filter.all;
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
                isFiltering
                    ? tr(context, '没有符合的模型', 'No matching models')
                    : tr(context, '还没有模型', 'No models yet'),
                style: GoogleFonts.inter(
                    fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                isFiltering
                    ? tr(context, '换个筛选条件试试。', 'Try another filter.')
                    : tr(context, '点击右下角按钮添加第一个模型。',
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
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
        : (model.status.isNotEmpty
            ? Colors.orange
            : cs.onSurface.withAlpha(120));
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
              const SizedBox(height: 6),
              Text(
                model.available
                    ? tr(context, '可用', 'Available')
                    : tr(context, '未配置', 'Unconfigured'),
                style: TextStyle(fontSize: 12, color: statusColor),
              ),
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
