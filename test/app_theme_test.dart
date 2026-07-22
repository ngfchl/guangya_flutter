import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/app/app_theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('toast always shows a dismiss button', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ShadToaster.of(
                context,
              ).show(const ShadToast(title: Text('可关闭通知'))),
              child: const Text('显示通知'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示通知'));
    await tester.pumpAndSettle();

    expect(find.text('可关闭通知'), findsOneWidget);
    final closeButton = find.byIcon(LucideIcons.x);
    expect(closeButton, findsOneWidget);

    await tester.tap(closeButton);
    await tester.pumpAndSettle();

    expect(find.text('可关闭通知'), findsNothing);
  });
}
