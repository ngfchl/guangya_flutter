import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/guangya_share_link.dart';

void main() {
  test('parses a Guangya share title and URL', () {
    final link = GuangyaShareLink.tryParse(
      'Z-斩神之凡尘神域.更07.4K臻彩10bit HiFi2.0&杜比音效\n'
      'https://www.guangyapan.com/s/1917051531925815352_ad9bQI8EdLN_2FUx',
    );

    expect(link, isNotNull);
    expect(link!.shareID, '1917051531925815352_ad9bQI8EdLN_2FUx');
    expect(link.title, 'Z-斩神之凡尘神域.更07.4K臻彩10bit HiFi2.0&杜比音效');
    expect(link.code, isEmpty);
  });

  test('parses extraction code after a share URL', () {
    final link = GuangyaShareLink.tryParse(
      'https://guangyapan.com/s/share_123 提取码：A8b2',
    );

    expect(link?.shareID, 'share_123');
    expect(link?.code, 'A8b2');
  });

  test('parses extraction code from URL query parameters', () {
    final link = GuangyaShareLink.tryParse(
      'https://www.guangyapan.com/s/'
      '1927017027028733956_aeWqASa0Twth-NXG?code=nizi',
    );

    expect(link?.shareID, '1927017027028733956_aeWqASa0Twth-NXG');
    expect(link?.code, 'nizi');
    expect(link?.url, endsWith('?code=nizi'));
  });

  test('ignores unrelated clipboard text', () {
    expect(GuangyaShareLink.tryParse('https://example.com/s/123'), isNull);
  });
}
