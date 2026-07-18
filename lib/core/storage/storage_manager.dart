import 'package:hive_flutter/hive_flutter.dart';

class StorageKeys {
  static const String apiBase = 'guangya.apiBase';
  static const String accountBase = 'guangya.accountBase';
  static const String accessToken = 'guangya.accessToken';
  static const String refreshToken = 'guangya.refreshToken';
  static const String deviceID = 'guangya.deviceID';
  static const String tokenExpiresAt = 'guangya.tokenExpiresAt';
  static const String baseUrl = 'guangya.baseUrl';
  static const String themeMode = 'guangya.themeMode';
  static const String tmdbApiKey = 'guangya.tmdbApiKey';
  static const String tmdbProxyHost = 'guangya.tmdbProxyHost';
  static const String tmdbProxyPort = 'guangya.tmdbProxyPort';
  static const String mediaLibraries = 'guangya.mediaLibraries';
  static const String mediaLibraryItems = 'guangya.mediaLibraryItems';
}

class StorageManager {
  static const String _boxName = 'guangya';
  static Box? _box;

  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
  }

  static Box get _instance {
    if (_box == null) throw StateError('StorageManager not initialized');
    return _box!;
  }

  static T? get<T>(String key) => _box?.get(key) as T?;

  static Future<void> set(String key, dynamic value) async {
    if (value == null) {
      await _instance.delete(key);
    } else {
      await _instance.put(key, value);
    }
  }

  static Future<void> delete(String key) async {
    await _instance.delete(key);
  }

  static Future<void> clear() async {
    await _instance.clear();
  }
}
