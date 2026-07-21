import '../models/media_library.dart';

String mediaArtworkDirectURL(String path, {required String size}) {
  final value = path.trim();
  if (value.startsWith('//')) return 'https:$value';
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) return value;
  if (value.startsWith('www.')) return 'https://$value';
  return 'https://image.tmdb.org/t/p/$size$value';
}

String? doubanPosterPath(Map<String, dynamic> candidate) {
  String? text(dynamic value) {
    if (value is! String) return null;
    final result = value.trim();
    return result.isEmpty || result == 'null' ? null : result;
  }

  final direct = text(candidate['cover_url']);
  if (direct != null) return direct;

  for (final field in ['cover_url', 'pic', 'cover', 'images']) {
    final value = candidate[field];
    if (value is! Map) continue;
    for (final key in ['large', 'normal', 'medium', 'small', 'url']) {
      final result = text(value[key]);
      if (result != null) return result;
    }
  }
  return null;
}

String? mediaBackdropPath(MediaLibraryItem item) {
  final backdrop = item.backdropPath?.trim();
  if (backdrop != null && backdrop.isNotEmpty) return backdrop;
  final poster = item.posterPath?.trim();
  return poster == null || poster.isEmpty ? null : poster;
}
