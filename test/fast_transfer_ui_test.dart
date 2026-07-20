import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/pages/workspace_tools_page.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  Future<void> pumpFastTransfer(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          home: Scaffold(
            body: WorkspaceToolsPage(
              tool: WorkspaceTool.fastTransfer,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('fast transfer starts with JSON source selection', (
    tester,
  ) async {
    await pumpFastTransfer(tester, const Size(1200, 800));

    expect(find.text('导入秒传任务'), findsOneWidget);
    expect(find.text('粘贴 JSON'), findsOneWidget);
    expect(find.text('选择 JSON'), findsOneWidget);
    expect(find.text('本地生成 JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fast transfer source selection fits a narrow window', (
    tester,
  ) async {
    await pumpFastTransfer(tester, const Size(520, 680));

    expect(find.text('导入秒传任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local JSON generator uses a scrollable preview workspace', (
    tester,
  ) async {
    await pumpFastTransfer(tester, const Size(1200, 800));

    await tester.tap(find.text('本地生成 JSON'));
    await tester.pumpAndSettle();

    expect(find.text('本地文件生成秒传 JSON'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('选择文件夹'), findsOneWidget);
    expect(find.text('复制 JSON'), findsOneWidget);
    expect(find.text('尚未生成 JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('imported JSON shows the queue with stable constraints', (
    tester,
  ) async {
    await Clipboard.setData(
      const ClipboardData(
        text:
            '{"path":"Movies/queue.mkv","size":"10","gcid":"0123456789abcdef0123456789abcdef01234567"}',
      ),
    );
    await pumpFastTransfer(tester, const Size(1200, 800));

    await tester.tap(find.text('粘贴 JSON'));
    await tester.pumpAndSettle();

    expect(find.text('秒传任务'), findsOneWidget);
    expect(find.text('开始秒传 1 项'), findsOneWidget);
    expect(find.text('主队列'), findsOneWidget);
    expect(find.text('queue.mkv'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
