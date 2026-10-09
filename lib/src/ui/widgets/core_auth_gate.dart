import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:remixicon/remixicon.dart';

import '../../core/core_api_client.dart';
import '../../core/service_manager.dart';
import 'bilingual_text.dart';

/// Core Web 后台的鉴权门禁：处理 dashboard 登录/首次设置密码，
/// 鉴权通过后把已登录的 [CoreApiClient] 交给 [builder]。
class CoreAuthGate extends StatefulWidget {
  final Widget Function(BuildContext context, CoreApiClient client) builder;

  const CoreAuthGate({super.key, required this.builder});

  @override
  State<CoreAuthGate> createState() => _CoreAuthGateState();
}

enum _GateState { loading, login, setup, ready, error }

class _CoreAuthGateState extends State<CoreAuthGate> {
  CoreApiClient? _client;
  _GateState _state = _GateState.loading;
  String _error = '';

  final _pwController = TextEditingController();
  bool _pwObscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _client = CoreApiClient(context.read<ServiceManager>().webUrl);
    _check();
  }

  @override
  void dispose() {
    _pwController.dispose();
    _client?.close();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _state = _GateState.loading;
      _error = '';
    });
    try {
      final st = await _client!.authStatus();
      if (!mounted) return;
      if (st['authenticated'] == true) {
        setState(() => _state = _GateState.ready);
      } else if (st['initialized'] == true) {
        setState(() => _state = _GateState.login);
      } else {
        setState(() => _state = _GateState.setup);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _GateState.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _submit() async {
    final pw = _pwController.text;
    if (pw.isEmpty) return;
    setState(() => _busy = true);
    try {
      if (_state == _GateState.setup) {
        await _client!.setupPassword(pw);
      } else {
        await _client!.login(pw);
      }
      if (!mounted) return;
      _pwController.clear();
      setState(() => _state = _GateState.ready);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(context, '验证失败：$e', 'Auth failed: $e')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 子页面在遇到 401 时可调用此方法回到登录态。
  void reauth() {
    if (mounted) setState(() => _state = _GateState.login);
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _GateState.loading:
        return const Scaffold(
            body: Center(child: CircularProgressIndicator()));
      case _GateState.login:
      case _GateState.setup:
        return Scaffold(body: _buildAuthForm(Theme.of(context).colorScheme));
      case _GateState.error:
        return Scaffold(body: _buildError(Theme.of(context).colorScheme));
      case _GateState.ready:
        return widget.builder(context, _client!);
    }
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Remix.error_warning_line,
                size: 48, color: cs.error.withAlpha(180)),
            const SizedBox(height: 16),
            Text(
              tr(context, '无法连接 Core 服务', 'Cannot reach Core service'),
              style:
                  GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _error,
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: cs.onSurface.withAlpha(150), fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _check,
              icon: const Icon(Remix.refresh_line),
              label: Text(tr(context, '重试', 'Retry')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthForm(ColorScheme cs) {
    final isSetup = _state == _GateState.setup;
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
                  color: cs.secondary.withAlpha(25),
                  shape: BoxShape.circle,
                ),
                child:
                    Icon(Remix.lock_line, size: 40, color: cs.secondary),
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
                    ? tr(context, '首次使用请设置控制台密码，用于保护控制台数据。',
                        'Set a dashboard password to protect console data.')
                    : tr(context, '请输入控制台密码。', 'Enter the dashboard password.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: cs.onSurface.withAlpha(160), fontSize: 14),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _pwController,
                obscureText: _pwObscure,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: tr(context, '密码', 'Password'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Remix.key_2_line),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _pwObscure ? Remix.eye_off_line : Remix.eye_line),
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
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
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
}
