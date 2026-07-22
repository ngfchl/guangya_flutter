import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/fetch_faster_github_proxy.dart';
import 'package:guangya_flutter/pages/app_upgrade_page.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  test('GitHub release response keeps version and downloadable assets', () {
    final update = AppUpdateInfo.fromGitHubJson({
      'tag_name': 'v1.2.3',
      'body': 'Changes',
      'published_at': '2026-07-22T10:00:00Z',
      'assets': [
        {
          'name': 'guangya_flutter-1.2.3_8-macos-arm64.pkg',
          'browser_download_url':
              'https://github.com/example/releases/download/v1.2.3/app.pkg',
          'size': 1048576,
        },
      ],
    });

    expect(update.version, '1.2.3');
    expect(update.body, 'Changes');
    expect(update.assets.single.formattedSize, '1.0 MB');
  });

  test('version comparison ignores build metadata', () {
    expect(compareAppVersions('1.0.7', '1.0.7+7'), 0);
    expect(compareAppVersions('v1.0.8', '1.0.7+99'), greaterThan(0));
    expect(compareAppVersions('1.0.6', '1.0.7'), lessThan(0));
  });

  test('saved GitHub proxy can be restored', () {
    const proxy = GithubProxyResponse(
      url: 'https://gh-proxy.net/',
      time: 120,
      status: 200,
    );

    expect(GithubProxyResponse.fromJson(proxy.toJson()).url, proxy.url);
    expect(GithubProxyResponse.fromJson(proxy.toJson()).time, 120);
  });

  for (final size in [const Size(1200, 800), const Size(390, 844)]) {
    testWidgets('upgrade dialog fits ${size.width.toInt()}px viewport', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.platformDispatcher
            .clearAllTestValues(),
      );
      const latest = AppUpdateInfo(
        version: '1.1.0',
        tagName: 'v1.1.0',
        body: 'Release notes',
        assets: [
          AppUpdateAsset(
            name: 'guangya_flutter-1.1.0-macos-arm64.pkg',
            url: 'https://github.com/example/app.pkg',
            size: 1024,
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUpgradeStatusProvider.overrideWith(
              (ref) async => const AppUpgradeStatus(
                currentVersion: '1.0.0+1',
                latest: latest,
                hasNewVersion: true,
                ignored: false,
                macosArch: 'arm64',
              ),
            ),
          ],
          child: ShadApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showAppUpgradeDialog(context),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('GitHub 下载加速'), findsOneWidget);
      expect(find.text('最新版本'), findsOneWidget);
      expect(find.text('历史版本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
