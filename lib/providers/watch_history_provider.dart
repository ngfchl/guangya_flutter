import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';

import '../core/storage/storage_manager.dart';
import '../models/watch_history.dart';

final watchHistoryProvider =
    StateNotifierProvider<WatchHistoryNotifier, List<WatchHistoryEntry>>(
      (ref) => WatchHistoryNotifier(),
    );

class WatchHistoryNotifier extends StateNotifier<List<WatchHistoryEntry>> {
  static const _maxEntries = 300;

  WatchHistoryNotifier() : super(const []) {
    unawaited(_load());
  }

  Future<void> record({
    required String fileID,
    required Duration position,
    required Duration duration,
  }) async {
    if (fileID.isEmpty || duration.inSeconds < 10 || position.inSeconds < 3) {
      return;
    }
    final progress = position.inMilliseconds / duration.inMilliseconds;
    final completed = progress >= 0.95;
    final entry = WatchHistoryEntry(
      fileID: fileID,
      positionMilliseconds: completed
          ? duration.inMilliseconds
          : position.inMilliseconds.clamp(0, duration.inMilliseconds).toInt(),
      durationMilliseconds: duration.inMilliseconds,
      updatedAt: DateTime.now(),
      completed: completed,
    );
    final next = [entry, ...state.where((item) => item.fileID != fileID)]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = next.take(_maxEntries).toList(growable: false);
    await _persist();
  }

  Future<void> removeFiles(Iterable<String> fileIDs) async {
    final ids = fileIDs.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final next = state
        .where((entry) => !ids.contains(entry.fileID))
        .toList(growable: false);
    if (next.length == state.length) return;
    state = next;
    await _persist();
  }

  Future<void> _load() async {
    final raw = StorageManager.get<dynamic>(StorageKeys.watchHistory);
    if (raw == null) return;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) return;
      state =
          decoded
              .whereType<Map>()
              .map(
                (item) =>
                    WatchHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((item) => item.fileID.isNotEmpty)
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (_) {
      // A malformed local history must never prevent media playback.
    }
  }

  Future<void> _persist() => StorageManager.set(
    StorageKeys.watchHistory,
    jsonEncode(state.map((item) => item.toJson()).toList()),
  );
}
