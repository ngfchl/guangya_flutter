import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/providers/media_library_provider.dart';

CloudFile directory(String name) =>
    CloudFile(id: name, name: name, isDirectory: true);

void main() {
  group('media scan optical-disc filtering', () {
    test('identifies Blu-ray and DVD internal paths', () {
      expect(
        isMediaScanDiscInternalPath('/Movies/Example/BDMV/STREAM/00000.m2ts'),
        isTrue,
      );
      expect(
        isMediaScanDiscInternalPath(r'Movies\\Example\\VIDEO_TS\\VTS_01_1.VOB'),
        isTrue,
      );
      expect(
        isMediaScanDiscInternalPath('/Movies/Example/Feature/01.m2ts'),
        isFalse,
      );
    });

    test('recognizes folders that are optical-disc roots', () {
      expect(isMediaScanDiscLayout([directory('BDMV')]), isTrue);
      expect(isMediaScanDiscLayout([directory('video_ts')]), isTrue);
      expect(
        isMediaScanDiscLayout([directory('Feature'), directory('Extras')]),
        isFalse,
      );
    });
  });
}
