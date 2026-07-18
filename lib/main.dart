import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'core/storage/storage_manager.dart';
import 'core/http/dio_client.dart';
import 'app/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init Hive for persistent storage
  await StorageManager.init();

  // Init Dio HTTP client
  DioClient.init();

  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(980, 640),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Trigger network permission
  _triggerNetworkPermission();

  runApp(const ProviderScope(child: GuangyaApp()));
}

/// Startup network permission trigger
void _triggerNetworkPermission() {
  Future.delayed(const Duration(seconds: 2), () async {
    try {
      final url = Uri.parse('https://www.baidu.com');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(url);
      await request.close();
      client.close();
    } catch (_) {
      // Silently ignore - permission dialog may have been shown
    }
  });
}
