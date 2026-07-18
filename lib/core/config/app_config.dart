import '../storage/storage_manager.dart';

class AppConfig {
  /// 光鸭 API 基础地址
  static const String _defaultApiBase = 'https://api.guangyapan.com';

  /// 光鸭账号基础地址
  static const String _defaultAccountBase = 'https://account.guangyapan.com';

  /// 客户端 ID
  static const String clientID = 'aMe-8VSlkrbQXpUR';

  /// 获取 API baseUrl（动态）
  static String get apiBase {
    return StorageManager.get<String>(StorageKeys.apiBase) ?? _defaultApiBase;
  }

  /// 设置 API baseUrl
  static Future<void> setApiBase(String url) async {
    await StorageManager.set(StorageKeys.apiBase, normalizeUrl(url));
  }

  /// 获取账号 baseUrl
  static String get accountBase {
    return StorageManager.get<String>(StorageKeys.accountBase) ?? _defaultAccountBase;
  }

  /// 设置账号 baseUrl
  static Future<void> setAccountBase(String url) async {
    await StorageManager.set(StorageKeys.accountBase, normalizeUrl(url));
  }

  static String normalizeUrl(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 清除所有配置
  static Future<void> clear() async {
    await StorageManager.delete(StorageKeys.apiBase);
    await StorageManager.delete(StorageKeys.accountBase);
  }
}
