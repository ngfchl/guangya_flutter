import 'package:flutter_riverpod/legacy.dart';
import '../core/storage/storage_manager.dart';

/// 用户手动调节的整体缩放系数，叠加在 [_lowPpiScale] 的自动值之上。
/// 默认 1.0 表示不额外缩放、沿用自动值；持久化到本地存储。
class ScaleNotifier extends StateNotifier<double> {
  ScaleNotifier() : super(1.0) {
    _load();
  }

  void _load() {
    final saved = StorageManager.get<String>(StorageKeys.uiScale);
    if (saved != null) {
      final v = double.tryParse(saved);
      if (v != null) {
        state = v.clamp(0.5, 1.5);
      }
    }
  }

  Future<void> setScale(double value) async {
    final clamped = value.clamp(0.5, 1.5);
    state = clamped;
    await StorageManager.set(StorageKeys.uiScale, clamped.toStringAsFixed(3));
  }
}

final scaleProvider = StateNotifierProvider<ScaleNotifier, double>(
  (ref) => ScaleNotifier(),
);
