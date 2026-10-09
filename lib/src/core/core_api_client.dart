import 'dart:convert';

import 'package:http/http.dart' as http;

import 'core_session.dart';

/// 访问 PicoClaw Web 后台 HTTP API 的客户端。
///
/// Web 后台（默认 http://127.0.0.1:18800）的 /api/* 需要 dashboard
/// 会话 cookie（`picoclaw_launcher_auth`）。未登录时服务端返回 401，
/// 此时抛出 [CoreApiAuthException]，由调用方弹出登录框处理。
class CoreApiClient {
  static const cookieName = 'picoclaw_launcher_auth';

  final String baseUrl;
  final http.Client _http = http.Client();
  String? _cookieValue;

  CoreApiClient(String baseUrl)
      : baseUrl = _normalizeBase(baseUrl),
        _cookieValue = CoreSession.cookie;

  /// 当前 dashboard 会话 cookie（登录后可用），用于 WebSocket 等需要
  /// Cookie 鉴权的场景。
  String? get sessionCookie => _cookieValue;

  /// WebSocket 代理地址，如 ws://127.0.0.1:18800
  String get wsBaseUrl {
    try {
      final u = Uri.parse(baseUrl);
      final wsScheme = u.scheme == 'https' ? 'wss' : 'ws';
      return u.replace(scheme: wsScheme).toString();
    } catch (_) {
      return baseUrl;
    }
  }

  static String _normalizeBase(String url) {
    try {
      final u = Uri.parse(url);
      if (u.host == '0.0.0.0') return u.replace(host: '127.0.0.1').toString();
    } catch (_) {}
    return url;
  }

  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (_cookieValue != null) {
      h['Cookie'] = '$cookieName=$_cookieValue';
    }
    return h;
  }

  void _storeCookie(http.Response resp) {
    final setCookie = resp.headers['set-cookie'];
    if (setCookie == null) return;
    for (final part in setCookie.split(',')) {
      final kv = part.split(';').first.trim();
      if (kv.startsWith('$cookieName=')) {
        _cookieValue = kv.substring(cookieName.length + 1);
        CoreSession.save(_cookieValue!);
        return;
      }
    }
  }

  Never _throwForStatus(http.Response resp) {
    if (resp.statusCode == 401) {
      _cookieValue = null;
      CoreSession.clear();
      throw CoreApiAuthException('unauthorized');
    }
    String detail = '';
    try {
      final body = jsonDecode(resp.body);
      if (body is Map) {
        detail = (body['error'] ?? body['message'] ?? '').toString();
      }
    } catch (_) {}
    throw CoreApiException(
      detail.isNotEmpty ? detail : 'HTTP ${resp.statusCode}',
      statusCode: resp.statusCode,
    );
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final resp = await _http.get(Uri.parse('$baseUrl$path'), headers: _headers);
    if (resp.statusCode != 200) _throwForStatus(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
      String path, Map<String, dynamic> body) async {
    final resp = await _http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _throwForStatus(resp);
    }
    _storeCookie(resp);
    if (resp.body.isEmpty) return {};
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> _putJson(
      String path, Map<String, dynamic> body) async {
    final resp = await _http.put(
      Uri.parse('$baseUrl$path'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _throwForStatus(resp);
    }
    if (resp.body.isEmpty) return {};
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _delete(String path) async {
    final resp =
        await _http.delete(Uri.parse('$baseUrl$path'), headers: _headers);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _throwForStatus(resp);
    }
  }

  // ---------------- 鉴权 ----------------

  /// 返回 {'authenticated': bool, 'initialized': bool}
  Future<Map<String, dynamic>> authStatus() => _getJson('/api/auth/status');

  Future<void> login(String password) async {
    final resp = await _http.post(
      Uri.parse('$baseUrl/api/auth/login'),
      headers: _headers,
      body: jsonEncode({'password': password}),
    );
    if (resp.statusCode != 200) _throwForStatus(resp);
    _storeCookie(resp);
    if (_cookieValue == null) {
      // 有些部署直接在响应体里返回成功，cookie 缺失则视为失败
      throw CoreApiException('login failed: no session cookie');
    }
  }

  Future<void> setupPassword(String password) async {
    await _postJson('/api/auth/setup', {
      'password': password,
      'confirm': password,
    });
  }

  // ---------------- 模型管理 ----------------

  Future<ModelsData> getModels() async {
    final json = await _getJson('/api/models');
    final models = <CoreModel>[];
    for (final m in (json['models'] as List? ?? [])) {
      if (m is Map<String, dynamic>) models.add(CoreModel.fromJson(m));
    }
    final providers = <ProviderOption>[];
    for (final p in (json['provider_options'] as List? ?? [])) {
      if (p is Map<String, dynamic>) providers.add(ProviderOption.fromJson(p));
    }
    return ModelsData(
      models: models,
      providers: providers,
      defaultModel: (json['default_model'] ?? '').toString(),
    );
  }

  Future<void> addModel(Map<String, dynamic> body) async {
    await _postJson('/api/models', body);
  }

  Future<void> updateModel(int index, Map<String, dynamic> body) async {
    await _putJson('/api/models/$index', body);
  }

  Future<void> deleteModel(int index) => _delete('/api/models/$index');

  Future<void> setDefaultModel(String modelName) async {
    await _postJson('/api/models/default', {'model_name': modelName});
  }

  Future<TestResult> testInline({
    required String provider,
    required String model,
    String apiBase = '',
    String apiKey = '',
    String authMethod = '',
    int? modelIndex,
  }) async {
    final body = <String, dynamic>{
      'provider': provider,
      'model': model,
      'api_base': apiBase,
      'api_key': apiKey,
      'auth_method': authMethod,
    };
    if (modelIndex != null) body['model_index'] = modelIndex;
    final json = await _postJson('/api/models/test-inline', body);
    return TestResult.fromJson(json);
  }

  /// 拉取提供商的可用模型 ID 列表。
  Future<List<String>> fetchProviderModels({
    required String provider,
    String apiBase = '',
    String apiKey = '',
    int? modelIndex,
  }) async {
    final body = <String, dynamic>{
      'provider': provider,
      'api_base': apiBase,
      'api_key': apiKey,
    };
    if (modelIndex != null) body['model_index'] = modelIndex;
    final json = await _postJson('/api/models/fetch', body);
    final ids = <String>[];
    for (final m in (json['models'] as List? ?? [])) {
      if (m is Map) {
        final id = (m['id'] ?? '').toString();
        if (id.isNotEmpty) ids.add(id);
      } else if (m is String && m.isNotEmpty) {
        ids.add(m);
      }
    }
    return ids;
  }

  void close() => _http.close();
}

class CoreApiException implements Exception {
  final String message;
  final int? statusCode;
  CoreApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class CoreApiAuthException extends CoreApiException {
  CoreApiAuthException(super.message);
}

class CoreModel {
  final int index;
  final String name;
  final String provider;
  final String model;
  final String apiBase;
  final String apiKeyMasked;
  final bool enabled;
  final bool available;
  final String status;
  final bool isDefault;

  CoreModel({
    required this.index,
    required this.name,
    required this.provider,
    required this.model,
    required this.apiBase,
    required this.apiKeyMasked,
    required this.enabled,
    required this.available,
    required this.status,
    required this.isDefault,
  });

  factory CoreModel.fromJson(Map<String, dynamic> j) => CoreModel(
        index: (j['index'] as num?)?.toInt() ?? 0,
        name: (j['model_name'] ?? '').toString(),
        provider: (j['provider'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
        apiBase: (j['api_base'] ?? '').toString(),
        apiKeyMasked: (j['api_key'] ?? '').toString(),
        enabled: j['enabled'] == true,
        available: j['available'] == true,
        status: (j['status'] ?? '').toString(),
        isDefault: j['is_default'] == true,
      );
}

class ProviderOption {
  final String id;
  final String label;
  final bool createAllowed;

  ProviderOption({
    required this.id,
    required this.label,
    required this.createAllowed,
  });

  factory ProviderOption.fromJson(Map<String, dynamic> j) => ProviderOption(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? j['id'] ?? '').toString(),
        createAllowed: j['create_allowed'] != false,
      );
}

class ModelsData {
  final List<CoreModel> models;
  final List<ProviderOption> providers;
  final String defaultModel;

  ModelsData({
    required this.models,
    required this.providers,
    required this.defaultModel,
  });
}

class TestResult {
  final bool success;
  final int latencyMs;
  final String status;
  final String error;

  TestResult({
    required this.success,
    required this.latencyMs,
    required this.status,
    required this.error,
  });

  factory TestResult.fromJson(Map<String, dynamic> j) => TestResult(
        success: j['success'] == true,
        latencyMs: (j['latency_ms'] as num?)?.toInt() ?? 0,
        status: (j['status'] ?? '').toString(),
        error: (j['error'] ?? '').toString(),
      );
}
