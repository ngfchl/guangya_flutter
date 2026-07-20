import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/widgets/app_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

void main() {
  testWidgets('app dialogs keep the route behind them visible', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showShadDialog<void>(
                context: context,
                builder: (_) => const ShadDialog(title: Text('透明遮罩测试')),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final dialogContext = tester.element(find.text('透明遮罩测试'));
    final route = ModalRoute.of(dialogContext);
    expect(route, isNotNull);
    expect(route!.barrierColor, Colors.transparent);
    expect(route.opaque, isFalse);
  });
}
