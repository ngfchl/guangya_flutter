import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('EasyRefresh builder accepts desktop mouse pull to refresh', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: EasyRefresh.builder(
            header: const ClassicHeader(),
            onRefresh: () async => refreshCount += 1,
            childBuilder: (context, physics) => ListView(
              physics: physics,
              children: const [SizedBox(height: 800)],
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(200, 120),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 180));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(refreshCount, 1);
  });
}
