part of '../workspace_page.dart';

class _GlobalScanTopAction extends ConsumerStatefulWidget {
  final bool compact;

  const _GlobalScanTopAction({required this.compact});

  @override
  ConsumerState<_GlobalScanTopAction> createState() =>
      _GlobalScanTopActionState();
}

class _GlobalScanTopActionState extends ConsumerState<_GlobalScanTopAction> {
  @override
  Widget build(BuildContext context) {
    return MediaScanMenu(
      compact: widget.compact,
      iconOnly: true,
      disabled: false,
      onScanUnrecognized: () => ref
          .read(mediaLibraryProvider.notifier)
          .scanGlobalLibrary(mode: MediaLibraryScanMode.unrecognizedOnly),
      onScanUnindexed: () => ref
          .read(mediaLibraryProvider.notifier)
          .scanGlobalLibrary(mode: MediaLibraryScanMode.unindexedOnly),
      onForceAll: () => ref
          .read(mediaLibraryProvider.notifier)
          .scanGlobalLibrary(mode: MediaLibraryScanMode.forceAll),
    );
  }
}
