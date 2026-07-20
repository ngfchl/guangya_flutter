import 'dart:io';

import 'package:guangya_flutter/models/media_library.dart';

void main(List<String> arguments) async {
  final home = Platform.environment['HOME'];
  if (home == null) throw StateError('HOME is not available');
  final database =
      '$home/Library/Containers/com.ptools.guangyaFlutter/Data/Documents/media-library.sqlite3';
  final result = await Process.run('sqlite3', [
    '-separator',
    '\t',
    database,
    "SELECT media_kind, cloud_name, resource_path FROM media_items WHERE COALESCE(tmdb_id,0)=0 ORDER BY resource_path;",
  ]);
  if (result.exitCode != 0) {
    throw StateError(result.stderr.toString());
  }

  final categories = <String, List<String>>{};
  final families = <String, int>{};
  var total = 0;
  for (final line in result.stdout.toString().split('\n')) {
    if (line.trim().isEmpty) continue;
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    total++;
    final storedKind = fields[0];
    final name = fields[1];
    final resourcePath = fields.sublist(2).join('\t');
    final segments = resourcePath
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final directoryName = segments.length >= 2
        ? segments[segments.length - 2]
        : null;
    final family = segments.length >= 2
        ? '/${segments.take(segments.length - 1).join('/')}'
        : resourcePath;
    families.update(family, (count) => count + 1, ifAbsent: () => 1);
    final parsed = ParsedMediaName.parse(
      name,
      directoryName: directoryName,
      directoryPath: resourcePath,
    );
    final labels = <String>[];
    if (parsed.title.trim().isEmpty ||
        RegExp(r'^(?:电影|电视剧|国产剧|其他)$').hasMatch(parsed.title)) {
      labels.add('标题无效');
    }
    if (parsed.year == null) labels.add('缺少年份');
    if (parsed.isEpisode && storedKind == 'movie') labels.add('剧集误存电影');
    if (!parsed.isEpisode && storedKind == 'tv') labels.add('剧集缺少集号');
    final pathHasResolution = RegExp(
      r'(?:2160p|1080p|720p|480p|4k|\d{3,4}x\d{3,4})',
      caseSensitive: false,
    ).hasMatch(resourcePath);
    if (pathHasResolution && parsed.resolution == null) labels.add('分辨率丢失');
    if (labels.isEmpty) labels.add('解析完整但未匹配');
    final description =
        '$resourcePath => title="${parsed.title}" year=${parsed.year ?? '-'} '
        'kind=${parsed.isEpisode ? 'tv' : storedKind} '
        'S${parsed.season ?? '-'}E${parsed.episode ?? '-'} '
        'resolution=${parsed.resolution ?? '-'}';
    for (final label in labels) {
      categories.putIfAbsent(label, () => []).add(description);
    }
  }

  stdout.writeln('Audited unmatched rows: $total');
  stdout.writeln('Unmatched directory families: ${families.length}');
  final repeatedFamilies =
      families.entries.where((entry) => entry.value > 1).toList(growable: false)
        ..sort((first, second) => second.value.compareTo(first.value));
  if (repeatedFamilies.isNotEmpty) {
    stdout.writeln('\nLargest unmatched families:');
    for (final entry in repeatedFamilies.take(12)) {
      stdout.writeln('  ${entry.value}x ${entry.key}');
    }
  }
  final sampleLimit = arguments.contains('--all') ? total : 12;
  for (final entry in categories.entries) {
    stdout.writeln('\n${entry.key}: ${entry.value.length}');
    for (final sample in entry.value.take(sampleLimit)) {
      stdout.writeln('  $sample');
    }
  }
}
