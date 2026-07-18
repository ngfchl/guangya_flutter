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
  });
}
