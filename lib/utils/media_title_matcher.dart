class MediaTitleMatch {
  final int score;
  final String basis;

  const MediaTitleMatch(this.score, this.basis);
}

class MediaTitleMatcher {
  static MediaTitleMatch bestTMDBMatch(
    String expected, {
    required String title,
    required String originalTitle,
  }) {
    final displayMatch = match(expected, title);
    final originalMatch = match(expected, originalTitle);
    if (originalMatch.score > displayMatch.score) {
      return MediaTitleMatch(originalMatch.score, '原名${originalMatch.basis}');
    }
    return MediaTitleMatch(displayMatch.score, '标题${displayMatch.basis}');
  }

  static MediaTitleMatch match(String expected, String candidate) {
    final literalExpected = literal(expected);
    final literalCandidate = literal(candidate);
    if (literalExpected.isEmpty || literalCandidate.isEmpty) {
      return const MediaTitleMatch(0, '');
    }
    if (literalExpected == literalCandidate) {
      return const MediaTitleMatch(120, '原样一致');
    }

    final compactExpected = normalize(expected);
    final compactCandidate = normalize(candidate);
    if (compactExpected == compactCandidate) {
      return const MediaTitleMatch(100, '标点归一一致');
    }

    final semanticExpected = semantic(expected);
    final semanticCandidate = semantic(candidate);
    if (semanticExpected == semanticCandidate) {
      return const MediaTitleMatch(95, '连接符归一一致');
    }

    if (_containsRelatedTitle(literalExpected, literalCandidate)) {
      return const MediaTitleMatch(55, '原样包含');
    }
    if (_containsRelatedTitle(compactExpected, compactCandidate)) {
      return const MediaTitleMatch(48, '标点归一包含');
    }
    if (_containsRelatedTitle(semanticExpected, semanticCandidate)) {
      return const MediaTitleMatch(45, '连接符归一包含');
    }
    return const MediaTitleMatch(0, '');
  }

  static int bestCandidateScore(
    Iterable<String> expectedTitles,
    Map<String, dynamic> candidate,
  ) {
    var best = 0;
    final titles = candidateTitles(candidate);
    for (final expected in expectedTitles) {
      for (final title in titles) {
        final score = match(expected, title).score;
        if (score > best) best = score;
      }
    }
    return best;
  }

  static Set<String> candidateTitles(Map<String, dynamic> candidate) {
    final titles = <String>{};
    void add(dynamic value) {
      final title = value?.toString().trim() ?? '';
      if (title.isNotEmpty) titles.add(title);
    }

    for (final key in const [
      'title',
      'name',
      'original_title',
      'original_name',
    ]) {
      add(candidate[key]);
    }
    final translations = candidate['translations'];
    final translationValues = translations is Map
        ? translations['translations']
        : translations;
    if (translationValues is List) {
      for (final value in translationValues) {
        if (value is! Map) continue;
        final data = value['data'];
        if (data is Map) {
          add(data['title']);
          add(data['name']);
        }
      }
    }
    final alternatives = candidate['alternative_titles'];
    final alternativeValues = alternatives is Map
        ? alternatives['results'] ?? alternatives['titles']
        : alternatives;
    if (alternativeValues is List) {
      for (final value in alternativeValues) {
        if (value is Map) add(value['title'] ?? value['name']);
      }
    }
    return titles;
  }

  static String literal(String value) {
    return _foldLatinDiacritics(value)
        .toLowerCase()
        .replaceAll(RegExp(r"[‘’`´]"), "'")
        .replaceAll(RegExp(r'[‐‑‒–—―]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String normalize(String value) {
    return literal(value).replaceAll(
      RegExp(r'[^a-z0-9\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af\u0400-\u052f]+'),
      '',
    );
  }

  static String semantic(String value) {
    return normalize(value.replaceAll('&', ' and ').replaceAll('＆', ' and '));
  }

  static bool _containsRelatedTitle(String first, String second) {
    if (first.length < 4 || second.length < 4) return false;
    if (!first.contains(second) && !second.contains(first)) return false;
    final containsNonLatin = RegExp(
      r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af\u0400-\u052f]',
    ).hasMatch(first + second);
    if (containsNonLatin) return true;

    final longer = first.length >= second.length ? first : second;
    final shorter = first.length >= second.length ? second : first;
    final index = longer.indexOf(shorter);
    if (index < 0) return false;
    final word = RegExp(r'[a-z0-9]');
    final startsAtBoundary = index == 0 || !word.hasMatch(longer[index - 1]);
    final end = index + shorter.length;
    final endsAtBoundary = end == longer.length || !word.hasMatch(longer[end]);
    return startsAtBoundary && endsAtBoundary;
  }

  static String _foldLatinDiacritics(String value) {
    const replacements = <String, String>{
      'àáâãäåāăą': 'a',
      'çćĉċč': 'c',
      'ďđ': 'd',
      'èéêëēĕėęě': 'e',
      'ĝğġģ': 'g',
      'ĥħ': 'h',
      'ìíîïĩīĭįı': 'i',
      'ĵ': 'j',
      'ķ': 'k',
      'ĺļľŀł': 'l',
      'ñńņňŉŋ': 'n',
      'òóôõöøōŏő': 'o',
      'ŕŗř': 'r',
      'śŝşš': 's',
      'ţťŧ': 't',
      'ùúûüũūŭůűų': 'u',
      'ŵ': 'w',
      'ýÿŷ': 'y',
      'źżž': 'z',
      'æ': 'ae',
      'œ': 'oe',
      'ß': 'ss',
    };
    var folded = value.toLowerCase();
    for (final entry in replacements.entries) {
      for (final character in entry.key.split('')) {
        folded = folded.replaceAll(character, entry.value);
      }
    }
    return folded;
  }
}
