import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/widgets/share_list_tile.dart';
import 'package:guangya_flutter/widgets/share_qr_code_panel.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  test('share records keep operation id separate from public share id', () {
    final share = CloudFile.fromJson({
      'id': '1927017027028733956',
      'shareId': '1927017027028733956_user',
      'code': 'nizi',
      'title': '来自：分享',
      'shareUrl':
          'https://www.guangyapan.com/s/1927017027028733956_user?code=nizi',
      'resType': 2,
    });

    expect(share.id, '1927017027028733956');
    expect(share.shareID, '1927017027028733956_user');
    expect(share.shareCode, 'nizi');
    expect(share.fileType, 8);
    expect(share.isDirectory, isFalse);
    expect(share.shareIsDirectory, isTrue);
    expect(share.shareKindName, '文件夹分享');
  });

  test('share cache round trip preserves link fields', () {
    final original = CloudFile.fromJson({
      'id': '123',
      'shareId': '123_user',
      'code': 'abcd',
      'title': '测试分享',
      'shareUrl': 'https://www.guangyapan.com/s/123_user?code=abcd',
      'resType': 2,
    });

    final restored = CloudFile.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.shareID, original.shareID);
    expect(restored.shareCode, original.shareCode);
    expect(restored.shareUrl, original.shareUrl);
    expect(restored.shareIsDirectory, original.shareIsDirectory);
    expect(restored.fileType, 8);
  });

  test('legacy cached share recovers share id from url', () {
    final restored = CloudFile.fromJson({
      'id': '123',
      'fileType': 8,
      'name': '旧缓存',
      'shareUrl': 'https://www.guangyapan.com/s/123_user?code=abcd',
    });

    expect(restored.shareID, '123_user');
    expect(restored.shareCode, 'abcd');
    expect(restored.shareUrl, isNotEmpty);
  });

  testWidgets('share tile displays link host and total size', (tester) async {
    const share = CloudFile(
      id: '123',
      name: '测试分享',
      isDirectory: false,
      size: 1024,
      fileType: 8,
      shareID: '123_user',
      shareCode: 'abcd',
      shareUrl: 'https://www.guangyapan.com/s/123_user?code=abcd',
      shareIsDirectory: false,
    );

    await tester.pumpWidget(
      const ShadApp(
        home: Scaffold(
          body: SizedBox(width: 1000, child: ShareListTile(share: share)),
        ),
      ),
    );

    expect(find.text('www.guangyapan.com'), findsOneWidget);
    expect(find.text('文件分享'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget);
  });

  testWidgets('share QR panel displays the share link below QR code', (
    tester,
  ) async {
    const link = 'https://www.guangyapan.com/s/123_user?code=abcd';

    await tester.pumpWidget(
      const ShadApp(
        home: Scaffold(
          body: ShareQRCodePanel(link: link, title: '测试分享'),
        ),
      ),
    );

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('小黄鸭分享'), findsOneWidget);
    expect(find.text('测试分享'), findsOneWidget);
    expect(find.text(link), findsOneWidget);
  });

  test('creates PNG bytes for copying a share QR code', () async {
    final bytes = await createShareQRCodePng(
      'https://www.guangyapan.com/s/123_user?code=abcd',
      title: '测试分享',
      size: 128,
    );

    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });
}
