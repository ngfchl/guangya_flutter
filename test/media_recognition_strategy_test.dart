import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/api/guangya_api.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/models/media_library.dart';
import 'package:guangya_flutter/providers/media_library_provider.dart';

class _RecognitionAPI extends GuangyaAPI {
  final calls = <({String query, String mediaKind, int? year})>[];

  @override
  Future<Map<String, dynamic>> tmdbSearch(
    String query, {
    required String apiKey,
    String mediaKind = 'auto',
    String proxyHost = '',
    String proxyPort = '',
    int? year,
  }) async {
    calls.add((query: query, mediaKind: mediaKind, year: year));
    if (query == '你好1983') {
      return {
        'results': [
          {
            'id': 280822,
            'media_type': 'tv',
            'name': '你好1983',
            'original_name': '你好1983',
            'first_air_date': '2026-03-17',
          },
        ],
      };
    }
    if (query == 'Project S01') {
      return {
        'results': [
          {
            'id': 999001,
            'media_type': 'tv',
            'name': 'Project S01',
            'original_name': 'Project S01',
            'first_air_date': '2026-01-01',
          },
        ],
      };
    }
    if (query == 'Inception') {
      return {
        'results': [
          {
            'id': 400001,
            'media_type': 'tv',
            'name': 'Inception',
            'original_name': 'Inception',
            'first_air_date': '2010-01-01',
          },
          {
            'id': 400002,
            'media_type': 'movie',
            'title': 'Inception',
            'original_title': 'Inception',
            'release_date': '2010-07-16',
          },
        ],
      };
    }
    if (query == 'April Story') {
      return {
        'results': [
          {
            'id': 200001,
            'media_type': 'movie',
            'title': '四月物语',
            'original_title': '四月物語',
            'release_date': '1998-03-14',
          },
        ],
      };
    }
    if (query == 'Belle The Dragon and the Freckled Princess') {
      return {
        'results': [
          {
            'id': 200018,
            'media_type': 'movie',
            'title': '龙和雀斑公主',
            'original_title': '竜とそばかすの姫',
          },
        ],
      };
    }
    if (query == 'The Fifth Element') {
      return {
        'results': [
          {
            'id': 200026,
            'media_type': 'movie',
            'title': '第五元素',
            'original_title': 'Le Cinquième Élément',
            'release_date': '1997-05-07',
          },
        ],
      };
    }
    if (query == 'Horton Hears A Who' && year == null) {
      return {
        'results': [
          {
            'id': 200027,
            'media_type': 'movie',
            'title': '霍顿与无名氏',
            'original_title': 'Horton Hears a Who!',
            'release_date': '2008-03-03',
          },
          {
            'id': 200028,
            'media_type': 'movie',
            'title': '霍顿孵蛋',
            'original_title': 'Horton Hatches the Egg',
            'release_date': '1970-03-18',
          },
        ],
      };
    }
    if (query == '向阳花开') {
      if (year == 2025) return const {'results': <Map<String, dynamic>>[]};
      return {
        'results': [
          {
            'id': 200029,
            'media_type': 'movie',
            'title': '向阳花开',
            'original_title': '向阳花开',
          },
          {
            'id': 200030,
            'media_type': 'movie',
            'title': '向阳花开',
            'original_title': '向阳花开',
          },
        ],
      };
    }
    if (query == '醉拳3') {
      return {
        'results': [
          {
            'id': 200031,
            'media_type': 'movie',
            'title': '醉拳3',
            'original_title': '醉拳III',
            'release_date': '1994-07-02',
          },
        ],
      };
    }
    if (query == '龙珠Z：神与神') {
      return {
        'results': [
          {
            'id': 200032,
            'media_type': 'movie',
            'title': '龙珠Z：神与神',
            'original_title': 'ドラゴンボールZ 神と神',
            'release_date': '2013-03-30',
          },
        ],
      };
    }
    if (query == 'Smaylik' && year == null) {
      return {
        'results': [
          {
            'id': 200033,
            'media_type': 'movie',
            'title': 'Смайлик',
            'original_title': 'Смайлик',
            'release_date': '2014-09-12',
          },
        ],
      };
    }
    if (query == 'Nomis' && year == null) {
      return {
        'results': [
          {
            'id': 200035,
            'media_type': 'movie',
            'title': 'Night Hunter',
            'original_title': 'Night Hunter',
            'release_date': '2019-08-29',
          },
        ],
      };
    }
    if (query == 'Pretty Cure All Stars: Spring Carnival') {
      return {
        'results': [
          {
            'id': 200034,
            'media_type': 'movie',
            'title': '光之美少女 All Stars 春之嘉年华♪',
            'original_title': '映画 プリキュアオールスターズ 春のカーニバル♪',
            'release_date': '2015-03-14',
          },
        ],
      };
    }
    if (query == 'Black Cat White Cat' && year == null) {
      return {
        'results': [
          {
            'id': 200022,
            'media_type': 'movie',
            'title': '黑猫白猫',
            'original_title': 'Crna mačka, beli mačor',
            'release_date': '1998-06-01',
          },
        ],
      };
    }
    if (query == 'Devils on the Doorstep' && year == null) {
      return {
        'results': [
          {
            'id': 200023,
            'media_type': 'movie',
            'title': '鬼子来了',
            'original_title': '鬼子来了',
            'release_date': '2000-05-12',
          },
        ],
      };
    }
    if (query == '钢铁人 1') {
      return {
        'results': [
          {
            'id': 200024,
            'media_type': 'movie',
            'title': '钢铁侠',
            'original_title': 'Iron Man',
            'release_date': '2008-04-30',
          },
          {
            'id': 200025,
            'media_type': 'movie',
            'title': '钢铁侠2',
            'original_title': 'Iron Man 2',
            'release_date': '2010-04-28',
          },
        ],
      };
    }
    if (query == 'Evangelion 3 0+1 0 Thrice Upon a Time') {
      return {
        'results': [
          {
            'id': 200019,
            'media_type': 'movie',
            'title': '新世纪福音战士新剧场版：终',
            'original_title': 'シン・エヴァンゲリオン劇場版:||',
            'release_date': '2021-03-08',
          },
        ],
      };
    }
    if (query == 'Гарри Поттер и Кубок огня') {
      return {
        'results': [
          {
            'id': 200020,
            'media_type': 'movie',
            'title': '哈利·波特与火焰杯',
            'original_title': 'Harry Potter and the Goblet of Fire',
            'release_date': '2005-11-16',
          },
          {
            'id': 200021,
            'media_type': 'movie',
            'title': '哈利·波特：魔法史',
            'original_title': 'Harry Potter: A History of Magic',
            'release_date': '2005-01-01',
          },
        ],
      };
    }
    if (query == '春日来信') {
      return {
        'results': [
          {
            'id': 200002,
            'media_type': 'movie',
            'title': '春天的信',
            'original_title': 'Spring Letter',
            'release_date': '2008-04-11',
          },
        ],
      };
    }
    if (query == 'Spiritual Kung Fu') {
      return {
        'results': [
          {
            'id': 200003,
            'media_type': 'movie',
            'title': '拳精',
            'original_title': '拳精',
            'release_date': '1978-12-01',
          },
        ],
      };
    }
    if (query == 'The Heaven Sword and Dragon Sabre') {
      return {
        'results': [
          {
            'id': 200004,
            'media_type': 'tv',
            'name': '倚天剑屠龙刀',
            'original_name': 'The Heaven Sword and Dragon Sabre',
            'first_air_date': '2001-04-09',
          },
        ],
      };
    }
    if (query == '笑傲江湖') {
      return {
        'results': [
          {
            'id': 200005,
            'media_type': 'tv',
            'name': '笑傲江湖',
            'original_name': 'State of Divinity',
            'first_air_date': '1996-06-24',
          },
        ],
      };
    }
    if (query == 'One Piece') {
      return {
        'results': [
          {
            'id': 200006,
            'media_type': 'tv',
            'name': '海贼王',
            'original_name': 'ONE PIECE',
            'first_air_date': '1999-10-20',
          },
        ],
      };
    }
    if (query == '守护解放西') {
      return {
        'results': [
          {
            'id': 200007,
            'media_type': 'tv',
            'name': '守护解放西',
            'original_name': '守护解放西',
            'first_air_date': '2019-09-14',
          },
        ],
      };
    }
    if (query == 'Leon The Professional') {
      return {
        'results': [
          {
            'id': 200008,
            'media_type': 'movie',
            'title': '这个杀手不太冷',
            'original_title': 'Léon: The Professional',
            'release_date': '1994-09-14',
          },
          {
            'id': 200009,
            'media_type': 'movie',
            'title': '另一部电影',
            'original_title': 'Another Film',
            'release_date': '1994-01-01',
          },
        ],
      };
    }
    if (query == 'Shanghai Triad') {
      return {
        'results': [
          {
            'id': 200010,
            'media_type': 'movie',
            'title': '摇啊摇，摇到外婆桥',
            'original_title': '摇啊摇，摇到外婆桥',
            'release_date': '1995-09-14',
          },
          {
            'id': 200011,
            'media_type': 'movie',
            'title': '上海往事',
            'original_title': '上海往事',
            'release_date': '2001-01-01',
          },
        ],
      };
    }
    if (query == 'Death Race') {
      return {
        'results': [
          {
            'id': 200012,
            'media_type': 'movie',
            'title': '死亡飞车',
            'original_title': 'Death Race',
            'release_date': '2008-08-22',
          },
        ],
      };
    }
    if (query == '亡命天涯') {
      return {
        'results': [
          {
            'id': 200013,
            'media_type': 'movie',
            'title': '亡命天涯',
            'original_title': 'The Fugitive',
            'release_date': '1993-08-06',
          },
          {
            'id': 200014,
            'media_type': 'movie',
            'title': '亡命天涯',
            'original_title': 'On the Run',
            'release_date': '1988-11-15',
          },
        ],
      };
    }
    if (query == 'The Fugitive') {
      return {
        'results': [
          {
            'id': 200013,
            'media_type': 'movie',
            'title': '亡命天涯',
            'original_title': 'The Fugitive',
            'release_date': '1993-08-06',
          },
        ],
      };
    }
    if (query == "Li'l Miss Vampire Can't Suck Right") {
      return {
        'results': [
          {
            'id': 200016,
            'media_type': 'tv',
            'name': '不擅长吸血的吸血鬼',
            'original_name': 'でこぼこ魔女の親子事情',
            'first_air_date': '2023-10-01',
          },
        ],
      };
    }
    if (query == '奇异博士') {
      return {
        'results': [
          {
            'id': 200017,
            'media_type': 'movie',
            'title': '奇异博士',
            'original_title': 'Doctor Strange',
            'release_date': '2016-10-25',
          },
        ],
      };
    }
    if (query == '雷霆沙赞') {
      return {
        'results': [
          {
            'id': 200015,
            'media_type': 'movie',
            'title': '雷霆沙赞！',
            'original_title': 'Shazam!',
            'release_date': '2019-03-29',
          },
        ],
      };
    }
    if (query == 'Chronicles of Grace and Grudges in the Primordial Age' ||
        query == '荒古恩仇录') {
      return {
        'results': [
          {
            'id': 300001,
            'media_type': 'tv',
            'name': '荒古恩仇录之破风篇',
            'original_name': '荒古恩仇录之破风篇',
            'first_air_date': '2025-09-17',
          },
        ],
      };
    }
    return const {'results': <Map<String, dynamic>>[]};
  }

  @override
  Future<Map<String, dynamic>> tmdbDetails(
    int id, {
    required String mediaKind,
    required String apiKey,
    String proxyHost = '',
    String proxyPort = '',
  }) async {
    if (id == 999001) {
      return {
        'id': id,
        'name': 'Project S01',
        'original_name': 'Project S01',
        'first_air_date': '2026-01-01',
      };
    }
    if (id == 300001) {
      return {
        'id': id,
        'name': '荒古恩仇录之破风篇',
        'original_name': '荒古恩仇录之破风篇',
        'first_air_date': '2025-09-17',
      };
    }
    if (id == 400002) {
      return {
        'id': id,
        'title': 'Inception',
        'original_title': 'Inception',
        'release_date': '2010-07-16',
      };
    }
    if (id == 200001) {
      return {
        'id': id,
        'title': '四月物语',
        'original_title': '四月物語',
        'release_date': '1998-03-14',
      };
    }
    if (id == 200002) {
      return {
        'id': id,
        'title': '春天的信',
        'original_title': 'Spring Letter',
        'release_date': '2008-04-11',
      };
    }
    if (id == 200018) {
      return {
        'id': id,
        'title': '龙和雀斑公主',
        'original_title': '竜とそばかすの姫',
        'release_date': '2021-07-16',
      };
    }
    if (id == 200019) {
      return {
        'id': id,
        'title': '新世纪福音战士新剧场版：终',
        'original_title': 'シン・エヴァンゲリオン劇場版:||',
        'release_date': '2021-03-08',
      };
    }
    if (id == 200020) {
      return {
        'id': id,
        'title': '哈利·波特与火焰杯',
        'original_title': 'Harry Potter and the Goblet of Fire',
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
    if (id == 200026) {
      return {
        'id': id,
        'title': '第五元素',
        'original_title': 'Le Cinquième Élément',
        'release_date': '1997-05-07',
        'alternative_titles': {
          'titles': [
            {'title': 'The Fifth Element'},
          ],
        },
      };
    }
    if (id == 200027) {
      return {
        'id': id,
        'title': '霍顿与无名氏',
        'original_title': 'Horton Hears a Who!',
        'release_date': '2008-03-03',
      };
    }
    if (id == 200028) {
      return {
        'id': id,
        'title': '霍顿孵蛋',
        'original_title': 'Horton Hatches the Egg',
        'release_date': '1970-03-18',
      };
    }
    if (id == 200029) {
      return {'id': id, 'title': '向阳花开', 'original_title': '向阳花开'};
    }
    if (id == 200030) {
      return {'id': id, 'title': '另一朵花', 'original_title': 'Another Flower'};
    }
    if (id == 200031) {
      return {
        'id': id,
        'title': '醉拳3',
        'original_title': '醉拳III',
        'release_date': '1994-07-02',
      };
    }
    if (id == 200032) {
      return {
        'id': id,
        'title': '龙珠Z：神与神',
        'original_title': 'ドラゴンボールZ 神と神',
        'release_date': '2013-03-30',
      };
    }
    if (id == 200033) {
      return {
        'id': id,
        'title': 'Смайлик',
        'original_title': 'Смайлик',
        'release_date': '2014-09-12',
        'alternative_titles': {
          'titles': [
            {'title': 'Smaylik'},
          ],
        },
      };
    }
    if (id == 200034) {
      return {
        'id': id,
        'title': '光之美少女 All Stars 春之嘉年华♪',
        'original_title': '映画 プリキュアオールスターズ 春のカーニバル♪',
        'release_date': '2015-03-14',
        'translations': {
          'translations': [
            {
              'data': {'title': 'Pretty Cure All Stars: Spring Carnival'},
            },
          ],
        },
      };
    }
    if (id == 200035) {
      return {
        'id': id,
        'title': 'Night Hunter',
        'original_title': 'Night Hunter',
        'release_date': '2019-08-29',
      };
    }
    if (id == 200022) {
      return {
        'id': id,
        'title': '黑猫白猫',
        'original_title': 'Crna mačka, beli mačor',
        'release_date': '1998-06-01',
        'alternative_titles': {
          'titles': [
            {'title': 'Black Cat, White Cat'},
          ],
        },
      };
    }
    if (id == 200023) {
      return {
        'id': id,
        'title': '鬼子来了',
        'original_title': '鬼子来了',
        'release_date': '2000-05-12',
        'translations': {
          'translations': [
            {
              'data': {'title': 'Devils on the Doorstep'},
            },
          ],
        },
      };
    }
    if (id == 200024) {
      return {
        'id': id,
        'title': '钢铁侠',
        'original_title': 'Iron Man',
        'release_date': '2008-04-30',
        'alternative_titles': {
          'titles': [
            {'title': '钢铁人 1'},
          ],
        },
      };
    }
    if (id == 200025) {
      return {
        'id': id,
        'title': '钢铁侠2',
        'original_title': 'Iron Man 2',
        'release_date': '2010-04-28',
        'alternative_titles': {
          'titles': [
            {'title': '钢铁人 2'},
          ],
        },
      };
    }
    if (id == 200021) {
      return {
        'id': id,
        'title': '哈利·波特：魔法史',
        'original_title': 'Harry Potter: A History of Magic',
        'release_date': '2005-01-01',
      };
    }
    if (id == 200003) {
      return {
        'id': id,
        'title': '拳精',
        'original_title': '拳精',
        'release_date': '1978-12-01',
      };
    }
    if (id == 200004) {
      return {
        'id': id,
        'name': '倚天剑屠龙刀',
        'original_name': 'The Heaven Sword and Dragon Sabre',
        'first_air_date': '2001-04-09',
      };
    }
    if (id == 200005) {
      return {
        'id': id,
        'name': '笑傲江湖',
        'original_name': 'State of Divinity',
        'first_air_date': '1996-06-24',
      };
    }
    if (id == 200006) {
      return {
        'id': id,
        'name': '海贼王',
        'original_name': 'ONE PIECE',
        'first_air_date': '1999-10-20',
      };
    }
    if (id == 200007) {
      return {
        'id': id,
        'name': '守护解放西',
        'original_name': '守护解放西',
        'first_air_date': '2019-09-14',
      };
    }
    if (id == 200008) {
      return {
        'id': id,
        'title': '这个杀手不太冷',
        'original_title': 'Léon: The Professional',
        'release_date': '1994-09-14',
      };
    }
    if (id == 200010) {
      return {
        'id': id,
        'title': '摇啊摇，摇到外婆桥',
        'original_title': '摇啊摇，摇到外婆桥',
        'release_date': '1995-09-14',
      };
    }
    if (id == 200012) {
      return {
        'id': id,
        'title': '死亡飞车',
        'original_title': 'Death Race',
        'release_date': '2008-08-22',
      };
    }
    if (id == 200013) {
      return {
        'id': id,
        'title': '亡命天涯',
        'original_title': 'The Fugitive',
        'release_date': '1993-08-06',
      };
    }
    if (id == 200015) {
      return {
        'id': id,
        'title': '雷霆沙赞！',
        'original_title': 'Shazam!',
        'release_date': '2019-03-29',
      };
    }
    if (id == 200016) {
      return {
        'id': id,
        'name': '不擅长吸血的吸血鬼',
        'original_name': 'でこぼこ魔女の親子事情',
        'first_air_date': '2023-10-01',
      };
    }
    if (id == 200017) {
      return {
        'id': id,
        'title': '奇异博士',
        'original_title': 'Doctor Strange',
        'release_date': '2016-10-25',
      };
    }
    return {
      'id': id,
      'name': '你好1983',
      'original_name': '你好1983',
      'first_air_date': '2026-03-17',
    };
  }
}

void main() {
  test('TV recognition falls back from filename to the raw parent title', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'episode-1',
        name:
            'Dream.of.Golden.Years.S01E01.2026.2160p.WEB-DL.H265.DV.DDP5.1-BlackTV.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/国产剧/你好1983/Dream.of.Golden.Years.S01E01.2026.2160p.WEB-DL.H265.DV.DDP5.1-BlackTV.mkv',
      ),
      directoryName: '你好1983',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 280822);
    expect(recognized.title, '你好1983');
    expect(api.calls.take(3).toList(), [
      (query: 'Dream of Golden Years', mediaKind: 'tv', year: 2026),
      (query: 'Dream of Golden Years', mediaKind: 'tv', year: null),
      (query: '你好1983', mediaKind: 'tv', year: 2026),
    ]);
  });

  test('persisted TMDB details reject an extra-letter English title', () {
    final notifier = MediaLibraryNotifier();
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'episode-24',
        name:
            'Everyone.Loves.Me.S01E24.1080p.Viu.WEB-DL.AAC2.0.H.264-BlackTV.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/国产剧/Everyone Loves Me/Everyone.Loves.Me.S01E24.1080p.Viu.WEB-DL.AAC2.0.H.264-BlackTV.mkv',
      ),
      directoryName: 'Everyone Loves Me',
    );

    final valid = notifier.validatePersistedTMDBDetailsForTesting(item, const {
      'id': 210098,
      'name': 'Everyone Loves Mel',
      'original_name': 'Everyone Loves Mel',
      'first_air_date': '2000-01-01',
    }, TMDBMediaKind.tv);

    expect(valid, isFalse);
  });

  test(
    'recognition preserves a real title that itself ends with S01',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'project-s01-episode-1',
          name: 'Project.S01.S01E01.2026.1080p.WEB-DL.mkv',
          isDirectory: false,
          cloudPath:
              '/电视剧/Project S01/Project.S01.S01E01.2026.1080p.WEB-DL.mkv',
        ),
        directoryName: 'Project S01',
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 999001);
      expect(recognized.title, 'Project S01');
      expect(api.calls.first.query, 'Project S01');
    },
  );

  test('recognition extracts English from a bilingual release title', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'chronicles-episode-1',
        name:
            '荒古恩仇录·破风篇.Chronicles.of.Grace.and.Grudges.in.the.Primordial.Age.S01E01.2025.2160p.WEB-DL.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/国产剧/荒古恩仇录·破风篇[全40集][国语配音+中文字幕].2025.2160p.WEB-DL.H265.HDR.AAC-ColorTV/'
            '荒古恩仇录·破风篇.Chronicles.of.Grace.and.Grudges.in.the.Primordial.Age.S01E01.2025.2160p.WEB-DL.mkv',
      ),
      directoryName:
          '荒古恩仇录·破风篇[全40集][国语配音+中文字幕].2025.2160p.WEB-DL.H265.HDR.AAC-ColorTV',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 300001);
    expect(recognized.title, '荒古恩仇录之破风篇');
    expect(
      api.calls,
      contains((
        query: 'Chronicles of Grace and Grudges in the Primordial Age',
        mediaKind: 'tv',
        year: 2025,
      )),
    );
  });

  test(
    'recognition falls back from a Chinese arc title to its series',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'chronicles-chinese-episode-1',
          name: '荒古恩仇录·破风篇.S01E01.2025.2160p.WEB-DL.mkv',
          isDirectory: false,
          cloudPath:
              '/电视剧/国产剧/荒古恩仇录·破风篇/荒古恩仇录·破风篇.S01E01.2025.2160p.WEB-DL.mkv',
        ),
        directoryName: '荒古恩仇录·破风篇',
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 300001);
      expect(
        api.calls,
        contains((query: '荒古恩仇录', mediaKind: 'tv', year: 2025)),
      );
    },
  );

  test(
    'recognition narrows mixed movie and TV results by media type',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'inception-movie',
          name: 'Inception.2010.1080p.BluRay.mkv',
          isDirectory: false,
          cloudPath: '/电影/Inception/Inception.2010.1080p.BluRay.mkv',
        ),
        directoryName: 'Inception',
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 400002);
      expect(recognized.mediaKind, TMDBMediaKind.movie);
      expect(api.calls.first, (
        query: 'Inception',
        mediaKind: 'movie',
        year: 2010,
      ));
    },
  );

  test('recognition accepts a localized unique exact-year result', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'april-story',
        name: 'April.Story.1998.1080p.BluRay.mkv',
        isDirectory: false,
        cloudPath: '/电影/April Story/April.Story.1998.1080p.BluRay.mkv',
      ),
      directoryName: 'April Story',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200001);
    expect(recognized.title, '四月物语');
  });

  test('unique exact-year fallback also supports Chinese queries', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'spring-letter',
        name: '春日来信.2008.1080p.BluRay.mkv',
        isDirectory: false,
        cloudPath: '/电影/春日来信/春日来信.2008.1080p.BluRay.mkv',
      ),
      directoryName: '春日来信',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200002);
    expect(recognized.title, '春天的信');
  });

  test(
    'year-constrained unique result remains usable without a result date',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'belle-2021',
          name:
              'Belle.The.Dragon.and.the.Freckled.Princess.2021.2160p.BluRay.mkv',
          isDirectory: false,
          cloudPath:
              '/电影/Belle.The.Dragon.and.the.Freckled.Princess.2021/'
              'Belle.The.Dragon.and.the.Freckled.Princess.2021.2160p.BluRay.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200018);
      expect(recognized.title, '龙和雀斑公主');
      expect(api.calls.first.year, 2021);
    },
  );

  test(
    'recognition preserves plus signs in Evangelion version titles',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'evangelion-2021',
          name:
              'Evangelion.3.0+1.0.Thrice.Upon.a.Time.2021.2160p.UHD.BluRay.mkv',
          isDirectory: false,
          cloudPath:
              '/电影/天鹰战士：最后的冲击[粤日多音轨+粤语配音+中文字幕].2021.2160p.UHD.BluRay/'
              'Evangelion.3.0+1.0.Thrice.Upon.a.Time.2021.2160p.UHD.BluRay.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200019);
      expect(api.calls.first.query, 'Evangelion 3 0+1 0 Thrice Upon a Time');
    },
  );

  test(
    'recognition verifies a single no-year result through alternative titles',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'black-cat-white-cat',
          name: 'Black.Cat.White.Cat.1998.SERBIAN.2160p.BluRay.REMUX.mkv',
          isDirectory: false,
          cloudPath:
              '/电影/Black.Cat.White.Cat.1998.SERBIAN.2160p.BluRay.REMUX/'
              'Black.Cat.White.Cat.1998.SERBIAN.2160p.BluRay.REMUX.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200022);
      expect(recognized.title, '黑猫白猫');
      expect(
        api.calls,
        contains((
          query: 'Black Cat White Cat',
          mediaKind: 'movie',
          year: null,
        )),
      );
    },
  );

  test(
    'recognition verifies a localized unique year result through details',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'fifth-element-1997',
          name: 'The.Fifth.Element.1997.2160p.BluRay.REMUX.mkv',
          isDirectory: false,
          cloudPath:
              '/电影/The.Fifth.Element.1997.2160p.BluRay.REMUX/'
              'The.Fifth.Element.1997.2160p.BluRay.REMUX.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200026);
      expect(recognized.title, '第五元素');
    },
  );

  test(
    'recognition accepts a one-year release date drift for exact titles',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'horton-2007',
          name: '[霍顿与无名氏].Horton.Hears.A.Who.2007.BluRay.mkv',
          isDirectory: false,
          cloudPath: '/电影/[霍顿与无名氏].Horton.Hears.A.Who.2007.BluRay.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200027);
      expect(recognized.title, '霍顿与无名氏');
    },
  );

  test(
    'recognition keeps a details-resolved candidate without release date',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'xiang-yang-hua-kai',
          name: '向阳花开.Xiang.Yang.Hua.Kai.2025.2160p.WEB-DL.mkv',
          isDirectory: false,
          cloudPath:
              '/电影/向阳花开.Xiang.Yang.Hua.Kai.2025.2160p.WEB-DL/'
              '向阳花开.Xiang.Yang.Hua.Kai.2025.2160p.WEB-DL.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200029);
      expect(recognized.title, '向阳花开');
    },
  );

  test('recognition cleans a leading year after removing cast notes', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'drunken-master-3',
        name: '1994.醉拳3(刘德华、李嘉欣).MP4',
        isDirectory: false,
        cloudPath: '/电影/刘德华电影(1)/1994.醉拳3(刘德华、李嘉欣).MP4',
      ),
    ).copyWith(mediaKind: TMDBMediaKind.movie);

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200031);
    expect(recognized.title, '醉拳3');
    expect(api.calls, contains((query: '醉拳3', mediaKind: 'movie', year: 1994)));
  });

  test(
    'recognition removes Dragon Ball movie ordinals and edition labels',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'dragon-ball-battle-of-gods',
          name: '龙珠Z剧场版18：神与神 加长版.mkv',
          isDirectory: false,
          cloudPath: '/电影/龙珠 剧场版/龙珠Z剧场版18：神与神 加长版.mkv',
        ),
      ).copyWith(mediaKind: TMDBMediaKind.movie);

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200032);
      expect(recognized.title, '龙珠Z：神与神');
      expect(api.calls.map((call) => call.query), contains('龙珠Z：神与神'));
    },
  );

  test(
    'recognition verifies a unique short Latin result through details',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'smaylik-2014',
          name: 'Smaylik.2014.RUSSIAN.1080p.WEBRip.x265-VXT.mp4',
          isDirectory: false,
          cloudPath:
              '/电影/Smaylik.2014.RUSSIAN.1080p.WEBRip.x265-VXT/'
              'Smaylik.2014.RUSSIAN.1080p.WEBRip.x265-VXT.mp4',
        ),
      ).copyWith(mediaKind: TMDBMediaKind.movie);

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200033);
      expect(recognized.title, 'Смайлик');
      expect(
        api.calls,
        contains((query: 'Smaylik', mediaKind: 'movie', year: null)),
      );
    },
  );

  test('recognition rejects an unrelated unique short result', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'nomis-2018',
        name: 'Nomis.2018.1080p.BluRay.AVC.TrueHD.5.1-TAPAS',
        isDirectory: false,
        cloudPath:
            '/电影/Nomis.2018.1080p.BluRay.AVC.TrueHD.5.1-TAPAS/'
            'Nomis.2018.1080p.BluRay.AVC.TrueHD.5.1-TAPAS',
      ),
    ).copyWith(mediaKind: TMDBMediaKind.movie);

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, isNull);
    expect(recognized.title, 'Nomis');
  });

  test('recognition treats an internal The as a subtitle connector', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'pretty-cure-spring-carnival',
        name: 'Pretty.Cure.All.Stars.The.Spring.Carnival.2015.1080p.BluRay.mkv',
        isDirectory: false,
        cloudPath:
            '/电影/光之美少女.春日嘉年华/'
            'Pretty.Cure.All.Stars.The.Spring.Carnival.2015.1080p.BluRay.mkv',
      ),
    ).copyWith(mediaKind: TMDBMediaKind.movie);

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200034);
    expect(
      api.calls.map((call) => call.query),
      contains('Pretty Cure All Stars: Spring Carnival'),
    );
  });

  test(
    'recognition verifies a no-year retry with the parsed release year',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'devils-on-the-doorstep',
          name: 'Devils.on.the.Doorstep.2000.DVDrip.720p.x265.mkv',
          isDirectory: false,
          cloudPath:
              '/电影/Devils.on.the.Doorstep.2000.DVDrip.720p.x265/'
              'Devils.on.the.Doorstep.2000.DVDrip.720p.x265.mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200023);
      expect(recognized.title, '鬼子来了');
    },
  );

  test(
    'recognition verifies short numbered Chinese aliases through details',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'iron-man-tw-1',
          name: '鋼鐵人 1.mkv',
          isDirectory: false,
          cloudPath: '/电影/鋼鐵人/鋼鐵人 1.mkv',
        ),
      ).copyWith(mediaKind: TMDBMediaKind.movie);

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200024);
      expect(recognized.title, '钢铁侠');
      expect(api.calls.map((call) => call.query), contains('钢铁人 1'));
    },
  );

  test(
    'recognition searches the work name after collection brackets',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'spiritual-kung-fu',
          name:
              '[成龙1976-1992蓝光原盘集1 Jackie Chan 1976-1992]'
              '[原盘国语中字][HDSKY][784.23GB]拳精 Spiritual Kung Fu 1978.iso',
          isDirectory: false,
          cloudPath:
              '/电影/成龙1976-2016原盘电影集/'
              '[成龙1976-1992蓝光原盘集1 Jackie Chan 1976-1992]'
              '[原盘国语中字][HDSKY][784.23GB]拳精 Spiritual Kung Fu 1978.iso',
        ),
        directoryName: '成龙1976-2016原盘电影集',
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200003);
      expect(
        api.calls,
        contains((query: 'Spiritual Kung Fu', mediaKind: 'movie', year: 1978)),
      );
    },
  );

  test('recognition tries controlled English spelling variants', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'heaven-sword-episode-1',
        name: 'The.Heaven.Sword.and.Dragon.Saber.S01E01.2001.2160p.WEB-DL.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/倚天剑屠龙刀[全42集].The.Heaven.Sword.and.Dragon.Saber.S01.2001/'
            'The.Heaven.Sword.and.Dragon.Saber.S01E01.2001.2160p.WEB-DL.mkv',
      ),
      directoryName: '倚天剑屠龙刀[全42集].The.Heaven.Sword.and.Dragon.Saber.S01.2001',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200004);
    expect(
      api.calls.any(
        (call) => call.query == 'The Heaven Sword and Dragon Sabre',
      ),
      isTrue,
    );
  });

  test(
    'recognition resolves localized Cyrillic candidates through translations',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'harry-potter-goblet-ru',
          name: 'Гарри Поттер и Кубок огня (2005).mkv',
          isDirectory: false,
          cloudPath:
              '/电影/DTS-X/Гарри Поттер/Гарри Поттер и Кубок огня (2005).mkv',
        ),
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200020);
      expect(recognized.title, '哈利·波特与火焰杯');
    },
  );

  test(
    'recognition removes two-digit edition years from old TV titles',
    () async {
      final api = _RecognitionAPI();
      final notifier = MediaLibraryNotifier()..api = api;
      addTearDown(notifier.dispose);
      final item = MediaLibraryItem.fromFile(
        'library-1',
        const CloudFile(
          id: 'state-of-divinity-episode-1',
          name: '01.rmvb',
          isDirectory: false,
          cloudPath: '/电视剧/[Tvb][笑傲江湖96][国语字幕43集][DVD-RMVB]/01.rmvb',
        ),
        directoryName: '[Tvb][笑傲江湖96][国语字幕43集][DVD-RMVB]',
      );

      final recognized = await notifier.recognizeMediaItemForTesting(
        item,
        apiKey: 'test-key',
      );

      expect(recognized.tmdbID, 200005);
      expect(api.calls.any((call) => call.query == '笑傲江湖'), isTrue);
    },
  );

  test('episode markers override a stale movie classification', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'one-piece-1097',
        name: '海贼王.One.Piece.S22E1097.1999.2160p.WEB-DL.mkv',
        isDirectory: false,
        cloudPath: '/电视剧/动漫/海贼王/海贼王.One.Piece.S22E1097.1999.2160p.WEB-DL.mkv',
      ),
      directoryName: '海贼王',
    ).copyWith(mediaKind: TMDBMediaKind.movie);

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200006);
    expect(recognized.mediaKind, TMDBMediaKind.tv);
    expect(
      api.calls.any(
        (call) => call.query == 'One Piece' && call.mediaKind == 'tv',
      ),
      isTrue,
    );
  });

  test('recognition tries a base title for numbered TV seasons', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'guard-jiefangxi-s02e01',
        name: '守护解放西2.Guard.Jie.Fang.Xi.S02E01.2020.2160p.WEB-DL.mkv',
        isDirectory: false,
        cloudPath:
            '/电视剧/纪录片/守护解放西2/守护解放西2.Guard.Jie.Fang.Xi.S02E01.2020.2160p.WEB-DL.mkv',
      ),
      directoryName: '守护解放西2',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200007);
    expect(api.calls.any((call) => call.query == '守护解放西'), isTrue);
  });

  test('recognition folds Latin diacritics during title matching', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'leon-1994',
        name: 'Leon.The.Professional.1994.2160p.BluRay.mkv',
        isDirectory: false,
        cloudPath:
            '/电影/Leon The Professional/Leon.The.Professional.1994.2160p.BluRay.mkv',
      ),
      directoryName: 'Leon The Professional',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200008);
  });

  test('recognition uses a related parent year for opaque file names', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'shanghai-triad-1995',
        name: 'abd-shanghaitriad1080p.mkv',
        isDirectory: false,
        cloudPath:
            '/电影/Shanghai.Triad.1995.1080p.BluRay.x264-aBD/abd-shanghaitriad1080p.mkv',
      ),
      directoryName: 'Shanghai.Triad.1995.1080p.BluRay.x264-aBD',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200010);
    expect(
      api.calls,
      contains((query: 'Shanghai Triad', mediaKind: 'movie', year: 1995)),
    );
  });

  test('recognition corrects a controlled title typo', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'death-race-2008',
        name:
            'Daeth.Race.2008.UNRATED.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1.mkv',
        isDirectory: false,
        cloudPath:
            '/电影/杰森斯坦森40部/死亡飞车① 蓝光原盘REMUX 内封字幕/'
            'Daeth.Race.2008.UNRATED.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1.mkv',
      ),
      directoryName: '死亡飞车① 蓝光原盘REMUX 内封字幕',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200012);
    expect(
      api.calls,
      contains((query: 'Death Race', mediaKind: 'movie', year: 2008)),
    );
  });

  test('recognition keeps searching after an ambiguous title result', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'fugitive-bilingual',
        name: '亡命天涯.The.Fugitive.mkv',
        isDirectory: false,
        cloudPath: '/电影/亡命天涯/亡命天涯.The.Fugitive.mkv',
      ),
      directoryName: '亡命天涯',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200013);
    expect(
      api.calls.map((call) => call.query),
      containsAllInOrder(['亡命天涯', 'The Fugitive']),
    );
  });

  test('recognition tries the first exclamation-delimited title', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'shazam-2019',
        name: '雷霆沙赞！沙赞！神力集结.2019.2160p.mkv',
        isDirectory: false,
        cloudPath: '/电影/雷霆沙赞！沙赞！神力集结.2019.2160p.mkv',
      ),
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200015);
    expect(api.calls.map((call) => call.query), contains('雷霆沙赞'));
  });

  test('recognition accepts a specific unique query without a year', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'vampire-2023-episode-1',
        name: "Li'l.Miss.Vampire.Can't.Suck.Right.S01E01.1080p.KKTV.WEB-DL.mkv",
        isDirectory: false,
        cloudPath:
            '/电视剧/国产剧/不擅长吸血的吸血鬼[全12集][中文字幕].1080p.KKTV.WEB-DL.AAC2.0.H.264/'
            "Li'l.Miss.Vampire.Can't.Suck.Right.S01E01.1080p.KKTV.WEB-DL.mkv",
      ),
      directoryName: '不擅长吸血的吸血鬼[全12集][中文字幕].1080p.KKTV.WEB-DL.AAC2.0.H.264',
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200016);
  });

  test('recognition adds simplified Chinese title variants', () async {
    final api = _RecognitionAPI();
    final notifier = MediaLibraryNotifier()..api = api;
    addTearDown(notifier.dispose);
    final item = MediaLibraryItem.fromFile(
      'library-1',
      const CloudFile(
        id: 'doctor-strange-traditional',
        name: '奇異博士 1.mkv',
        isDirectory: false,
        cloudPath: '/电影/漫威系列/奇異博士/奇異博士 1/奇異博士 1.mkv',
      ),
    );

    final recognized = await notifier.recognizeMediaItemForTesting(
      item,
      apiKey: 'test-key',
    );

    expect(recognized.tmdbID, 200017);
    expect(api.calls.map((call) => call.query), contains('奇异博士'));
  });
}
