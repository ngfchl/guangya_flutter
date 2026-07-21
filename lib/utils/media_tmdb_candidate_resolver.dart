import 'media_title_matcher.dart';

class TMDBCandidateResolution {
  final List<Map<String, dynamic>> candidates;
  final List<String> diagnostics;

  const TMDBCandidateResolution(this.candidates, this.diagnostics);
}

class MediaTMDBCandidateResolver {
  static List<Map<String, dynamic>> refine({
    required Iterable<Map<String, dynamic>> candidates,
    required String expectedType,
    required int? year,
    required Iterable<String> titleEvidence,
  }) {
    var pool = candidates
        .where((candidate) {
          if (expectedType == 'auto') return true;
          return candidate['media_type']?.toString() == expectedType;
        })
        .toList(growable: false);
    if (pool.isEmpty) return const [];

    final exact = pool
        .where((candidate) {
          return MediaTitleMatcher.bestCandidateScore(
                titleEvidence,
                candidate,
              ) >=
              95;
        })
        .toList(growable: false);
    if (exact.isNotEmpty) pool = exact;

    if (year != null) {
      final sameYear = pool
          .where((candidate) {
            final date =
                (candidate['release_date'] ?? candidate['first_air_date'])
                    ?.toString() ??
                '';
            return date.startsWith('$year');
          })
          .toList(growable: false);
      if (sameYear.isNotEmpty) pool = sameYear;
    }
    final unique = <String, Map<String, dynamic>>{};
    for (final candidate in pool) {
      final type = candidate['media_type']?.toString() ?? expectedType;
      final id = candidate['id']?.toString();
      unique[id == null || id.isEmpty
              ? '$type:${candidate.hashCode}'
              : '$type:$id'] =
          candidate;
    }
    return unique.values.toList(growable: false);
  }

  static Future<TMDBCandidateResolution> resolveAmbiguous({
    required List<Map<String, dynamic>> candidates,
    required int? year,
    required Iterable<String> titleEvidence,
    required Future<Map<String, dynamic>> Function(int id, String mediaType)
    loadDetails,
  }) async {
    final needsDetails = candidates.any(
      (candidate) => candidate['_recognitionNeedsDetails'] == true,
    );
    if (candidates.length <= 1 && !needsDetails) {
      return TMDBCandidateResolution(candidates, const []);
    }
    final evidence = titleEvidence.toList(growable: false);
    final diagnostics = <String>[];
    final ranked =
        <({int score, int titleScore, Map<String, dynamic> value})>[];
    for (final candidate in candidates.take(6)) {
      final id = int.tryParse(candidate['id']?.toString() ?? '');
      final type = candidate['media_type']?.toString();
      if (id == null || (type != 'movie' && type != 'tv')) continue;
      var merged = Map<String, dynamic>.from(candidate);
      try {
        final details = await loadDetails(id, type!);
        merged = {...candidate, ...details, 'id': id, 'media_type': type};
      } catch (error) {
        diagnostics.add('id=$id 详情请求失败：$error');
      }
      final titleScore = MediaTitleMatcher.bestCandidateScore(evidence, merged);
      final date =
          (merged['release_date'] ?? merged['first_air_date'])?.toString() ??
          '';
      var score = titleScore;
      final candidateYear = _releaseYear(date);
      if (year != null && candidateYear != null) {
        final delta = (candidateYear - year).abs();
        if (delta == 0) {
          score += 30;
        } else if (delta == 1) {
          score += 20;
        } else {
          score -= 40;
        }
      }
      ranked.add((score: score, titleScore: titleScore, value: merged));
      diagnostics.add(
        'id=$id 标题评分=$titleScore，年份=${date.isEmpty ? '-' : date}，总分=$score',
      );
    }
    if (candidates.length == 1 && needsDetails) {
      if (ranked.isNotEmpty && ranked.first.titleScore >= 95) {
        diagnostics.add('详情与多语言标题收敛到 id=${ranked.first.value['id']}');
        return TMDBCandidateResolution([
          {...ranked.first.value, '_recognitionResolvedByDetails': true},
        ], diagnostics);
      }
      return TMDBCandidateResolution(candidates, diagnostics);
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    if (ranked.isEmpty || ranked.first.titleScore < 95) {
      return TMDBCandidateResolution(candidates, diagnostics);
    }
    final second = ranked.length > 1 ? ranked[1] : null;
    final uniquelyExact = second == null || second.titleScore < 95;
    final decisiveGap =
        second == null || ranked.first.score - second.score >= 20;
    if (!uniquelyExact && !decisiveGap) {
      return TMDBCandidateResolution(candidates, diagnostics);
    }
    diagnostics.add('详情与多语言标题收敛到 id=${ranked.first.value['id']}');
    return TMDBCandidateResolution([
      {...ranked.first.value, '_recognitionResolvedByDetails': true},
    ], diagnostics);
  }

  static int? _releaseYear(String date) {
    if (date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }
}
