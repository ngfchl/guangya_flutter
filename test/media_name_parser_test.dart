import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/media_library.dart';

void main() {
  group('ParsedMediaName', () {
    test('extracts standard season episode and technical tags', () {
      final value = ParsedMediaName.parse(
        'Pursuit.of.Jade.S01E33.2026.2160p.WEB-DL.H265.HDR.60fps.DDP5.1.Atmos.mkv',
      );

      expect(value.season, 1);
      expect(value.episode, 33);
      expect(value.year, 2026);
      expect(value.resolution, '2160p');
      expect(value.source, 'WEB-DL');
      expect(value.videoCodec, 'H265');
      expect(value.dynamicRange, 'HDR');
      expect(value.audio, 'DDP5');
    });

    test('accepts episode-only and Chinese episode conventions', () {
      final english = ParsedMediaName.parse(
        'Immortal.Samsara.2022.E45.WEB-DL.4k.H265.AAC.mp4',
      );
      final chinese = ParsedMediaName.parse('超能立方 - 第 3 集 - 混战！.2160p.mkv');

      expect(english.season, 1);
      expect(english.episode, 45);
      expect(chinese.season, 1);
      expect(chinese.episode, 3);
    });

    test(
      'uses a trailing number as an episode when the folder title matches',
      () {
        final value = ParsedMediaName.parse(
          '知否知否应是绿肥红瘦 26.mp4',
          directoryName: '知否知否应是绿肥红瘦',
          directoryPath: '/电视剧/国产剧/知否知否应是绿肥红瘦/知否知否应是绿肥红瘦 26.mp4',
        );

        expect(value.title, '知否知否应是绿肥红瘦');
        expect(value.season, 1);
        expect(value.episode, 26);
        expect(value.isEpisode, isTrue);
      },
    );

    test('removes a release group and parses an attached episode number', () {
      final value = ParsedMediaName.parse(
        '[TxTPS]-笑傲江湖37.国语字幕.风中使者.d-vb.rmvb',
        directoryName: '笑傲江湖',
        directoryPath: '/电视剧/国产剧/笑傲江湖/[TxTPS]-笑傲江湖37.国语字幕.风中使者.d-vb.rmvb',
      );

      expect(value.title, '笑傲江湖');
      expect(value.season, 1);
      expect(value.episode, 37);
      expect(value.isEpisode, isTrue);
    });

    test('keeps apostrophes in English titles', () {
      final value = ParsedMediaName.parse(
        "Li'l.Miss.Vampire.Can't.Suck.Right.S01E01.1080p.WEB-DL.mkv",
      );

      expect(value.title, "Li'l Miss Vampire Can't Suck Right");
      expect(value.season, 1);
      expect(value.episode, 1);
    });

    test('supports four-digit episode numbers for long-running series', () {
      final value = ParsedMediaName.parse(
        '海贼王.One.Piece.S22E1097.1999.2160p.WEB-DL.mkv',
      );

      expect(value.title, '海贼王');
      expect(value.season, 22);
      expect(value.episode, 1097);
      expect(value.isEpisode, isTrue);
    });

    test('removes uploader suffixes from legacy TV folder titles', () {
      final value = ParsedMediaName.parse(
        '01.rmvb',
        directoryName: '倚天屠龙记@猪猪乐园@zerocool9527',
        directoryPath: '/电视剧/倚天屠龙记@猪猪乐园@zerocool9527/01.rmvb',
      );

      expect(value.title, '倚天屠龙记');
      expect(value.season, 1);
      expect(value.episode, 1);
    });

    test('keeps an attached number when it belongs to the directory title', () {
      final value = ParsedMediaName.parse('西游记2.mp4', directoryName: '西游记2');

      expect(value.title, '西游记2');
      expect(value.episode, isNull);
      expect(value.isEpisode, isFalse);
    });

    test('extracts a movie title after studio metadata and year', () {
      final value = ParsedMediaName.parse('中国香港邵氏出品.1968.拜倒石榴裙.mkv');

      expect(value.title, '拜倒石榴裙');
      expect(value.year, 1968);
      expect(value.isEpisode, isFalse);
    });

    test('extracts movie titles after leading archive years', () {
      final parenthesized = ParsedMediaName.parse(
        '(1985)夏日福星(高清).MP4',
        directoryName: '刘德华电影(1)',
      );
      final separated = ParsedMediaName.parse(
        '1972 合气道.mkv',
        directoryName: '洪金宝电影(1)',
      );

      expect(parenthesized.title, '夏日福星');
      expect(parenthesized.year, 1985);
      expect(separated.title, '合气道');
      expect(separated.year, 1972);
    });

    test('preserves a numeric movie title before its release year', () {
      final value = ParsedMediaName.parse(
        '2046.2004.CHINESE.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.5.1-FGT.mkv',
        directoryName: 'BluRay.REMUX-HD.M5.1',
      );

      expect(value.title, '2046');
      expect(value.year, 2004);
      expect(value.resolution, '2160p');
    });

    test('removes download-site prefixes from localized movie titles', () {
      final heaven = ParsedMediaName.parse(
        '[电影天堂www.dytt89.com]源氏物语：千年之谜BD日语中字.mp4',
      );
      final bay = ParsedMediaName.parse(
        '[电影湾dy196.com]消失的子弹.1080p.1.92g.H264.AAC.mkv',
      );

      expect(heaven.title, '源氏物语：千年之谜');
      expect(bay.title, '消失的子弹');
    });

    test('uses the work suffix after bracketed collection metadata', () {
      final value = ParsedMediaName.parse(
        '[成龙1976-1992蓝光原盘集1 Jackie Chan 1976-1992]'
        '[原盘国语中字][HDSKY][784.23GB]拳精 Spiritual Kung Fu 1978.iso',
      );

      expect(value.title, '拳精');
      expect(value.year, 1978);
    });

    test('keeps film year and ignores unresolvable disc stream names', () {
      final movie = ParsedMediaName.parse('加勒比海盗5：死无对证(2017).1080p.mp4');
      final stream = ParsedMediaName.parse(
        '01076.m2ts',
        directoryName: '加勒比海盗5：死无对证(2017)',
      );

      expect(movie.year, 2017);
      expect(movie.resolution, '1080p');
      expect(movie.isEpisode, isFalse);
      expect(stream.title, '加勒比海盗5：死无对证');
      expect(stream.year, 2017);
    });

    test('uses parent season information for numeric episode file names', () {
      final fromSeasonFolder = ParsedMediaName.parse(
        '02.mkv',
        directoryName: '示例剧集 Season 3 2160p WEB-DL',
      );
      final compact = ParsedMediaName.parse(
        '0102.mkv',
        directoryName: '示例剧集 1080p',
      );

      expect(fromSeasonFolder.season, 3);
      expect(fromSeasonFolder.episode, 2);
      expect(fromSeasonFolder.isEpisode, isTrue);
      expect(compact.season, 1);
      expect(compact.episode, 2);
      expect(compact.isEpisode, isTrue);
    });

    test('removes Chinese disc release notes before matching a movie', () {
      final value = ParsedMediaName.parse(
        '003.刺客信条刺客教条(港台) [SGNB第三部UHD原盘DIY BDJ菜单修改 次时代国语音轨 国配简英繁特效四字幕]Assassins Creed 2016 ULTRAHD Blu-ray 2160p HEVC Atoms TrueHD 7.1-sGnb@CHDBits.iso',
      );

      expect(value.title, '刺客信条刺客教条');
      expect(value.year, 2016);
      expect(value.resolution, '2160p');
      expect(value.videoCodec, 'HEVC');
      expect(value.audio, 'TrueHD');
    });

    test('removes bracketed numeric prefixes from localized titles', () {
      final value = ParsedMediaName.parse('【002】白玉老虎.mkv');

      expect(value.title, '白玉老虎');
    });

    test('removes collection dates and noisy language release tags', () {
      final dated = ParsedMediaName.parse(
        '2022年11月11日 黑豹2.瓦坎达万岁.2022.1080p.国英双语.中英特效字幕.无水印纯净版.mkv',
      );
      final bilingual = ParsedMediaName.parse(
        '倚天屠龙记之魔教教主.重新调色版.国粤双语中字Kung.Fu.Cult.Master.1993.HKG.BluRay.H265.10Bit.1080P-.mkv',
      );

      expect(dated.title, '黑豹2 瓦坎达万岁');
      expect(dated.year, 2022);
      expect(bilingual.title, '倚天屠龙记之魔教教主 重新调色版');
      expect(bilingual.year, 1993);
      expect(bilingual.resolution, '1080P');
    });

    test('prefers a later release year and detects nonstandard resolution', () {
      final laterYear = ParsedMediaName.parse(
        '2025.The.World.Enslaved.By.A.Virus.2021.1080p.WEBRip.x264-RARBG.mp4',
      );
      final legacy = ParsedMediaName.parse('野兽之瞳.1024x576.国粤双语.中文字幕.mkv');

      expect(laterYear.title, 'The World Enslaved By A Virus');
      expect(laterYear.year, 2021);
      expect(laterYear.resolution, '1080p');
      expect(legacy.title, '野兽之瞳');
      expect(legacy.resolution, '1024x576');
    });

    test('uses a Chinese movie title after a leading year in its folder', () {
      final value = ParsedMediaName.parse(
        '2008.mkv',
        directoryName: '2008见龙卸甲',
      );

      expect(value.title, '见龙卸甲');
      expect(value.year, 2008);
      expect(value.isEpisode, isFalse);
    });

    test('removes a season marker from a numeric series title', () {
      final compact = ParsedMediaName.parse('1883.S01E01.1080p.WEB-DL.mkv');
      final separated = ParsedMediaName.parse('1883 S01 E01 1080p WEB-DL.mkv');

      expect(compact.title, '1883');
      expect(compact.season, 1);
      expect(compact.episode, 1);
      expect(separated.title, '1883');
      expect(separated.season, 1);
      expect(separated.episode, 1);
    });

    test('keeps a season-only pack searchable as its series title', () {
      final value = ParsedMediaName.parse('1883 S01.mkv');

      expect(value.title, '1883');
      expect(value.season, 1);
      expect(value.episode, isNull);
    });

    test(
      'uses a meaningful ancestor for a numeric episode in nested folders',
      () {
        final value = ParsedMediaName.parse(
          '01.mkv',
          directoryPath:
              '/电影/七龙珠 系列/L 龙!珠!大!魔!（2024）[更新至20集]4K EDR高码率/4K 高码率[更新至20集]/01.mkv',
        );

        expect(value.title, '龙 珠 大 魔');
        expect(value.year, 2024);
      },
    );

    test('treats ASCII and full-width punctuation as title separators', () {
      final value = ParsedMediaName.parse(
        'All｜Creatures，Great……＆Small.2020.S01E01.1080p.mkv',
      );

      expect(value.title, 'All Creatures Great and Small');
      expect(value.year, 2020);
      expect(value.season, 1);
      expect(value.episode, 1);
    });

    test('extracts a localized title from a season release folder', () {
      final value = ParsedMediaName.parse(
        'X医生：外科医生大门未知子 第5季[全10集][无字片源].1080p.AMZN.WEB-DL',
      );

      expect(value.title, 'X医生：外科医生大门未知子');
      expect(value.season, 5);
    });

    test('treats a short numeric file in a named folder as an episode', () {
      final value = ParsedMediaName.parse(
        '13.2160p.HD国语中字无水印.mkv',
        directoryName: '女神蒙上眼',
        directoryPath: '/电视剧/女神蒙上眼/13.2160p.HD国语中字无水印.mkv',
      );

      expect(value.title, '女神蒙上眼');
      expect(value.year, isNull);
      expect(value.season, 1);
      expect(value.episode, 13);
      expect(value.isEpisode, isTrue);
    });

    test('uses the show folder for a dated variety-show episode', () {
      final value = ParsedMediaName.parse(
        '20260406.第1期加更.mp4',
        directoryName: '哈｜哈哈哈哈 第六季',
        directoryPath: '/电视剧/综艺/国产剧/Season6/哈｜哈哈哈哈 第六季/20260406.第1期加更.mp4',
      );

      expect(value.title, '哈 哈哈哈哈');
      expect(value.season, 6);
      expect(value.episode, 1);
      expect(value.isEpisode, isTrue);
    });

    test('accepts spaced season and episode markers in damaged names', () {
      final value = ParsedMediaName.parse(
        '再见爱人 - S 2E2 - 第1 期：一生何求（下）.mp4',
        directoryName: '再见爱人(2 21){TMDB-13 99}-1 8 p',
      );

      expect(value.title, '再见爱人');
      expect(value.season, 2);
      expect(value.episode, 2);
      expect(value.isEpisode, isTrue);
      final missingZero = ParsedMediaName.parse(
        '再见爱人 - S 2E1 - 第5期：相爱后动物感伤（下）.mp4',
      );
      expect(missingZero.season, 2);
      expect(missingZero.episode, 10);
      expect(
        ParsedMediaName.parse('再见爱人(2 21){TMDB-13 99}-1 8 p').resolution,
        '1080p',
      );
    });

    test('repairs spaced zero digits in parent folder years', () {
      final value = ParsedMediaName.parse(
        '第67集 七擒孟获.mp4',
        directoryName: '16(2  3){TMDB-1 63 2}-未知分辨率',
        directoryPath: '/电视剧/国产剧/其他剧/16(2  3){TMDB-1 63 2}-未知分辨率/第67集 七擒孟获.mp4',
      );

      expect(value.title, '其他剧');
      expect(value.year, 2003);
      expect(value.season, 1);
      expect(value.episode, 67);
      expect(value.isEpisode, isTrue);
    });

    test('extracts title and episode from a multi-bracket release name', () {
      final value = ParsedMediaName.parse(
        '[GM-Team][国漫][完美世界][Perfect World][2021][192][AVC][GB][1080P].mp4',
        directoryName:
            '[GM-Team][国漫][完美世界][Perfect World][2021][192-195][AVC][GB][1080P]',
        directoryPath:
            '/电视剧/国产剧/[GM-Team][国漫][完美世界][Perfect World][2021][192-195][AVC][GB][1080P]/'
            '[GM-Team][国漫][完美世界][Perfect World][2021][192][AVC][GB][1080P].mp4',
      );

      expect(value.title, '完美世界');
      expect(value.year, 2021);
      expect(value.season, 1);
      expect(value.episode, 192);
      expect(value.resolution, '1080P');
      expect(value.videoCodec, 'AVC');
      expect(value.isEpisode, isTrue);
    });

    test('removes a single-letter Chinese folder sort prefix', () {
      final value = ParsedMediaName.parse(
        'S01E01.2026.2160p.60fps.WEB-DL.H265.10bit.AAC.mp4',
        directoryName: 'Q-翘楚',
        directoryPath:
            '/电视剧/国产剧/Q-翘楚/S01E01.2026.2160p.60fps.WEB-DL.H265.10bit.AAC.mp4',
      );

      expect(value.title, '翘楚');
      expect(value.year, 2026);
      expect(value.season, 1);
      expect(value.episode, 1);
    });

    test('extracts a season marker attached directly to a Chinese title', () {
      final value = ParsedMediaName.parse('骄阳伴我S01');

      expect(value.title, '骄阳伴我');
      expect(value.season, 1);
      expect(value.episode, isNull);
    });
  });
}
