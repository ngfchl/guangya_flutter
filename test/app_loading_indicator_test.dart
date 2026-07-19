import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/widgets/app_loading_indicator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  Future<({Size size, double strokeWidth})> pumpAtWidth(
    WidgetTester tester,
    double width,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    await tester.pumpWidget(
      const ShadApp(
        home: Scaffold(
          body: AppLoadingIndicator(size: AppLoadingSize.page, label: '正在加载'),
        ),
      ),
    );
    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    return (
      size: tester.getSize(find.byType(CircularProgressIndicator)),
      strokeWidth: indicator.strokeWidth ?? 0,
    );
  }

  testWidgets('loading indicator scales with the window width', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final compact = await pumpAtWidth(tester, 390);
    final desktop = await pumpAtWidth(tester, 1440);

    expect(desktop.size.width, greaterThan(compact.size.width));
    expect(desktop.strokeWidth, greaterThan(compact.strokeWidth));
    expect(find.text('正在加载'), findsOneWidget);
  });
}
