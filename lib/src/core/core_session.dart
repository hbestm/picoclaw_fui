import 'package:shared_preferences/shared_preferences.dart';

/// Core Web 后台的登录会话：把 dashboard 会话 cookie 持久化，
/// 避免切 Tab / 重启 App 后反复要求输入密码。
///
/// cookie 是 core 进程内随机生成的，core 服务重启后会失效，
/// 此时服务端返回 401，调用方应清除会话并重新登录。
class CoreSession {
  static const _key = 'core_dashboard_session_cookie';

  static String? _cookie;
  static bool _loaded = false;

  /// App 启动时调用一次，把缓存的 cookie 读进内存。
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cookie = prefs.getString(_key);
    } catch (_) {
      _cookie = null;
    }
    _loaded = true;
  }

  static String? get cookie => _cookie;

  static Future<void> save(String cookie) async {
    _cookie = cookie;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, cookie);
    } catch (_) {}
  }

  static Future<void> clear() async {
    _cookie = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
