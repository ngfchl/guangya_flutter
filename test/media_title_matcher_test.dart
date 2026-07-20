import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/utils/media_title_matcher.dart';
import 'package:guangya_flutter/utils/media_tmdb_candidate_resolver.dart';

void main() {
  test('normalizes Cyrillic titles without dropping their characters', () {
    expect(
      MediaTitleMatcher.match(
        'Гарри Поттер и Кубок огня',
        'Гарри Поттер и Кубок огня',
      ).score,
      120,
    );
  });

  test('uses TMDB translations and alternative titles as evidence', () {
    final candidate = <String, dynamic>{
      'title': 'Harry Potter and the Goblet of Fire',
      'original_title': 'Harry Potter and the Goblet of Fire',
      'translations': {
        'translations': [
          {
            'iso_639_1': 'ru',
            'data': {'title': 'Гарри Поттер и Кубок огня'},
          },
        ],
      },
      'alternative_titles': {
        'titles': [
          {'title': 'Harry Potter 4'},
        ],
      },
    };

    expect(
      MediaTitleMatcher.bestCandidateScore(const [
        'Гарри Поттер и Кубок огня',
      ], candidate),
      120,
    );
    expect(
      MediaTitleMatcher.candidateTitles(candidate),
      containsAll(<String>[
        'Harry Potter and the Goblet of Fire',
        'Гарри Поттер и Кубок огня',
        'Harry Potter 4',
      ]),
    );
  });

  test(
    'ambiguous localized candidates converge through TMDB translations',
    () async {
      final resolution = await MediaTMDBCandidateResolver.resolveAmbiguous(
        candidates: const [
          {
            'id': 1,
            'media_type': 'movie',
            'title': 'Harry Potter and the Goblet of Fire',
            'release_date': '2005-11-16',
          },
          {
            'id': 2,
            'media_type': 'movie',
            'title': 'Harry Potter: A History of Magic',
            'release_date': '2005-01-01',
          },
        ],
        year: 2005,
        titleEvidence: const ['Гарри Поттер и Кубок огня'],
        loadDetails: (id, mediaType) async {
          if (id == 1) {
            return {
              'id': id,
              'title': 'Harry Potter and the Goblet of Fire',
              'release_date': '2005-11-16',
              'translations': {
                'translations': [
                  {
                    'data': {'title': 'Гарри Поттер и Кубок огня'},
                  },
                ],
              },
            };
          }
          return {
            'id': id,
            'title': 'Harry Potter: A History of Magic',
            'release_date': '2005-01-01',
          };
        },
      );

      expect(resolution.candidates, hasLength(1));
      expect(resolution.candidates.single['id'], 1);
    },
  );
}
