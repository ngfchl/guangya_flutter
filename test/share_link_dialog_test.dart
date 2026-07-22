import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/widgets/share_link_dialog.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('share result switches from link to QR code on mobile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.platformDispatcher
          .clearAllTestValues(),
    );

    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showShareLinkDialog(
                context,
                createLink: () async =>
                    'https://www.guangyapan.com/s/share_test',
              ),
              child: const Text('打开分享'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开分享'));
    await tester.pumpAndSettle();
    expect(
      find.text('https://www.guangyapan.com/s/share_test'),
      findsOneWidget,
    );

    await tester.tap(find.text('二维码'));
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
