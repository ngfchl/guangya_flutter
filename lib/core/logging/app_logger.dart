import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum AppLogLevel { debug, info, warning, error }

class AppLogEntry {
  final DateTime timestamp;
  final AppLogLevel level;
  final String scope;
  final String origin;
  final String message;

  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.scope,
    this.origin = '',
    required this.message,
  });

  String get text =>
      '${timestamp.toIso8601String()} [${_levelLabel(level)}] '
      '[${_scopeLabel(scope)}]${origin.isEmpty ? '' : '[$origin]'} $message';

  static String _levelLabel(AppLogLevel level) => switch (level) {
    AppLogLevel.debug => '调试',
    AppLogLevel.info => '信息',
    AppLogLevel.warning => '警告',
    AppLogLevel.error => '错误',
  };

  static String _scopeLabel(String scope) => switch (scope) {
    'HTTP' => '网络',
    'Auth' => '认证',
    'Media' => '媒体库',
    'Backup' => '数据备份',
    'CloudIndex' => '全盘索引',
    'Player' => '播放器',
    'Storage' => '本地存储',
    'App' => '应用',
    'Flutter' => '界面',
    'Dart' => '运行时',
    _ => scope,
  };
}

/// One log sink for debug console, release file diagnostics and the in-app log
/// viewer. Never write request headers or authorization tokens here.
class AppLogger {
  static const _maxEntries = 1200;
  static final entries = ValueNotifier<List<AppLogEntry>>(const []);
  static File? _file;
  static Future<void> _pendingWrite = Future.value();

  static Future<void> initialize() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final logsDirectory = Directory(path.join(directory.path, 'logs'));
      await logsDirectory.create(recursive: true);
      _file = File(path.join(logsDirectory.path, 'guangya.log'));
      if (await _file!.exists() && await _file!.length() > 4 * 1024 * 1024) {
        await _file!.rename(
          path.join(logsDirectory.path, 'guangya.previous.log'),
        );
      }
      info('App', '日志中心已初始化：${_file!.path}');
    } catch (error) {
      developer.log('日志中心初始化失败：$error', name: 'Guangya');
    }
  }

  static void debug(String scope, String message) =>
      _write(AppLogLevel.debug, scope, message);
  static void info(String scope, String message) =>
      _write(AppLogLevel.info, scope, message);
  static void warning(String scope, String message) =>
      _write(AppLogLevel.warning, scope, message);
  static void error(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _write(
    AppLogLevel.error,
    scope,
    error == null ? message : '$message：$error',
    stackTrace: stackTrace,
  );

  static void clear() => entries.value = const [];

  static void _write(
    AppLogLevel level,
    String scope,
    String message, {
    StackTrace? stackTrace,
  }) {
    if (kReleaseMode && level == AppLogLevel.debug) return;
    final origin = _callerOrigin(StackTrace.current);
    final entry = AppLogEntry(
      timestamp: DateTime.now(),
      level: level,
      scope: scope,
      origin: origin,
      message: message,
    );
    final next = [...entries.value, entry];
    entries.value = next.length > _maxEntries
        ? next.sublist(next.length - _maxEntries)
        : next;
    developer.log(
      entry.text,
      name: 'Guangya',
      level: switch (level) {
        AppLogLevel.debug => 500,
        AppLogLevel.info => 800,
        AppLogLevel.warning => 900,
        AppLogLevel.error => 1000,
      },
      stackTrace: stackTrace,
    );
    final file = _file;
    if (file == null) return;
    _pendingWrite = _pendingWrite
        .then((_) async {
          await file.writeAsString(
            '${entry.text}${stackTrace == null ? '' : '\n$stackTrace'}\n',
            mode: FileMode.append,
            flush: false,
          );
        })
        .catchError((_) {});
  }

  static String _callerOrigin(StackTrace stackTrace) {
    for (final line in stackTrace.toString().split('\n')) {
      if (line.contains('/app_logger.dart:')) continue;
      final packageLocation = RegExp(
        r'package:guangya_flutter/([^:]+):(\d+):\d+',
      ).firstMatch(line);
      final fileLocation = RegExp(
        r'/(lib|test)/([^:]+):(\d+):\d+',
      ).firstMatch(line);
      final relativePath = packageLocation?.group(1) ?? fileLocation?.group(2);
      final lineNumber = packageLocation?.group(2) ?? fileLocation?.group(3);
      if (relativePath == null || lineNumber == null) continue;
      final function = RegExp(r'^#\d+\s+(.+?)\s+\(').firstMatch(line)?.group(1);
      return '$relativePath:$lineNumber${function == null ? '' : ' $function'}';
    }
    return '';
  }
}
