import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../core/storage/storage_manager.dart';

class ThemeState {
  final ThemeMode themeMode;
  const ThemeState({this.themeMode = ThemeMode.system});

  ThemeState copyWith({ThemeMode? themeMode}) =>
      ThemeState(themeMode: themeMode ?? this.themeMode);
}

class ThemeNotifier extends StateNotifier<ThemeState> {
  ThemeNotifier() : super(const ThemeState()) {
    _load();
  }

  void _load() {
    final saved = StorageManager.get<String>(StorageKeys.themeMode);
    if (saved == 'light') {
      state = const ThemeState(themeMode: ThemeMode.light);
    } else if (saved == 'dark') {
      state = const ThemeState(themeMode: ThemeMode.dark);
    } else {
      state = const ThemeState();
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final name =
        mode == ThemeMode.light ? 'light' : mode == ThemeMode.dark ? 'dark' : 'system';
    await StorageManager.set(StorageKeys.themeMode, name);
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeState>(
  (ref) => ThemeNotifier(),
);
