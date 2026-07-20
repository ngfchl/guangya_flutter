import '../models/media_library.dart';
import 'media_title_matcher.dart';

/// Reuses a previously verified TMDB identity only when the local library has
/// one unambiguous identity for the exact normalized title.
class MediaKnownMatchIndex {
  final Map<String, Map<int, MediaLibraryItem>> _matches = {};

  MediaKnownMatchIndex(Iterable<MediaLibraryItem> items) {
    for (final item in items) {
      add(item);
    }
  }

  void add(MediaLibraryItem item) {
    final id = item.tmdbID;
    final kind = item.mediaKind;
    if (id == null || kind == null || kind == TMDBMediaKind.automatic) return;

    for (final title in {item.title, item.originalTitle}) {
      final normalized = MediaTitleMatcher.normalize(title);
      if (normalized.isEmpty) continue;
      final key = '${kind.name}:$normalized';
      _matches.putIfAbsent(key, () => {})[id] = item;
    }
  }

  MediaLibraryItem? resolve({
    required String title,
    required TMDBMediaKind mediaKind,
    int? year,
  }) {
    final normalized = MediaTitleMatcher.normalize(title);
    if (normalized.isEmpty || mediaKind == TMDBMediaKind.automatic) return null;
    final matches = _matches['${mediaKind.name}:$normalized'];
    if (matches == null || matches.isEmpty) return null;

    final candidates = year == null
        ? matches
        : Map<int, MediaLibraryItem>.fromEntries(
            matches.entries.where((entry) => entry.value.year == '$year'),
          );
    return candidates.length == 1 ? candidates.values.single : null;
  }
}
