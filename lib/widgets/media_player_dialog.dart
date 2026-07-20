import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../core/logging/app_logger.dart';
import '../providers/file_provider.dart';
import '../providers/watch_history_provider.dart';
import 'app_loading_indicator.dart';

Future<void> showMediaPlayerDialog(
  BuildContext context,
  CloudFile file, {
  List<CloudFile> episodeCandidates = const [],
  CloudFile? initialSubtitle,
}) async {
  Future<void> openExternalPlayer() async {
    await Future<void>.delayed(Duration.zero);
    if (!context.mounted) return;
    await showShadDialog<void>(
      context: context,
      builder: (_) => ExternalPlayerDialog(file: file),
    );
  }

  try {
    await showShadDialog<void>(
      context: context,
      builder: (_) => MediaPlayerDialog(
        file: file,
        episodeCandidates: episodeCandidates,
        initialSubtitle: initialSubtitle,
        onPlaybackFailure: openExternalPlayer,
      ),
    );
  } catch (error, stackTrace) {
    AppLogger.warning('Player', '内置播放器窗口异常，正在打开外部播放器：$error');
    AppLogger.debug('Player', stackTrace.toString());
    await openExternalPlayer();
  }
}

class MediaPlayerDialog extends ConsumerStatefulWidget {
  final CloudFile file;
  final List<CloudFile> episodeCandidates;
  final CloudFile? initialSubtitle;
  final Future<void> Function()? onPlaybackFailure;

  const MediaPlayerDialog({
    super.key,
    required this.file,
    this.episodeCandidates = const [],
    this.initialSubtitle,
    this.onPlaybackFailure,
  });

  @override
  ConsumerState<MediaPlayerDialog> createState() => _MediaPlayerDialogState();
}

class _MediaPlayerDialogState extends ConsumerState<MediaPlayerDialog> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _videoDimensionFallbackTimer;
  late CloudFile _currentFile;
  String? _error;
  bool _loading = true;
  bool _externalFallbackOpened = false;
  var _videoAspectRatio = 3 / 2;
  var _hasVideoDimensions = false;
  bool _showEpisodes = false;
  int _lastRecordedSeconds = 0;
  List<CloudFile> _episodes = const [];
  List<CloudFile> _subtitleCandidates = const [];

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: PlayerConfiguration(async: !Platform.isMacOS),
    );
    try {
      _controller = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          // The macOS OpenGL texture backend can abort libmpv while creating
          // a render context. Software textures keep the embedded player
          // stable; other desktop and mobile platforms retain GPU output.
          enableHardwareAcceleration: !Platform.isMacOS,
          hwdec: Platform.isMacOS ? 'no' : null,
        ),
      );
      unawaited(
        _controller.platform.future.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            _handlePlaybackFailure(
              error,
              error is MissingPluginException ? '内置播放器插件未加载' : '内置视频输出初始化失败',
            );
          },
        ),
      );
    } catch (error) {
      _handlePlaybackFailure(error, '内置视频输出初始化失败');
    }
    _currentFile = widget.file;
    _videoParamsSubscription = _player.stream.videoParams.listen(
      _updateVideoDimensions,
    );
    _positionSubscription = _player.stream.position.listen(
      _recordPlaybackProgress,
    );
    _episodes = _matchingEpisodes(widget.file, widget.episodeCandidates);
    Future.microtask(_open);
  }

  Future<void> _open([CloudFile? file]) async {
    if (file != null && file.id != _currentFile.id) {
      _saveCurrentPlaybackProgress();
      _lastRecordedSeconds = 0;
    }
    _videoDimensionFallbackTimer?.cancel();
    if (mounted) {
      setState(() {
        if (file != null) _currentFile = file;
        _loading = true;
        _error = null;
        _hasVideoDimensions = false;
        _videoAspectRatio = 3 / 2;
      });
    }
    try {
      // NativeVideoController applies mpv output configuration asynchronously.
      // Opening only after it is ready avoids racing the render context setup.
      await _controller.platform.future;
      final url = await ref
          .read(fileProvider.notifier)
          .playbackUrl(_currentFile);
      await _player.open(Media(url.toString()), play: true);
      final initialSubtitle = widget.initialSubtitle;
      if (initialSubtitle != null) {
        await _setDirectorySubtitle(initialSubtitle);
      }
      _videoDimensionFallbackTimer?.cancel();
      _videoDimensionFallbackTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _loading && _error == null) {
          setState(() => _loading = false);
        }
      });
      final siblings = await ref
          .read(fileProvider.notifier)
          .siblingMediaFiles(_currentFile);
      final episodeSources = <String, CloudFile>{
        for (final candidate in widget.episodeCandidates)
          candidate.id: candidate,
        for (final candidate in siblings) candidate.id: candidate,
      }.values.toList();
      final folderFiles = await ref
          .read(fileProvider.notifier)
          .siblingFiles(_currentFile);
      if (mounted) {
        setState(() {
          _episodes = _matchingEpisodes(_currentFile, episodeSources);
          _subtitleCandidates = _matchingSubtitles(_currentFile, folderFiles);
        });
      }
    } catch (error) {
      _handlePlaybackFailure(error, '内置播放器打开失败');
    }
  }

  void _handlePlaybackFailure(Object error, String message) {
    AppLogger.warning('Player', '$message，准备切换外部播放器：$error');
    if (!mounted) return;
    setState(() {
      _error = '$message：$error';
      _loading = false;
    });
    if (_externalFallbackOpened || widget.onPlaybackFailure == null) return;
    _externalFallbackOpened = true;
    unawaited(() async {
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await Navigator.of(context).maybePop();
      await widget.onPlaybackFailure!();
    }());
  }

  void _recordPlaybackProgress(Duration position) {
    final duration = _player.state.duration;
    if (duration.inSeconds < 10 || position.inSeconds < 3) return;
    final completed = position >= duration * 0.95;
    if (!completed && position.inSeconds - _lastRecordedSeconds < 10) return;
    _lastRecordedSeconds = position.inSeconds;
    unawaited(
      ref
          .read(watchHistoryProvider.notifier)
          .record(
            fileID: _currentFile.id,
            position: position,
            duration: duration,
          ),
    );
  }

  void _saveCurrentPlaybackProgress() {
    _recordPlaybackProgress(_player.state.position);
  }

  void _updateVideoDimensions(VideoParams params) {
    final width = params.dw ?? params.w;
    final height = params.dh ?? params.h;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final aspect = params.aspect ?? width / height;
    if (aspect < 0.25 || aspect > 4 || !mounted) return;
    _videoDimensionFallbackTimer?.cancel();
    setState(() {
      _videoAspectRatio = aspect;
      _hasVideoDimensions = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _error == null) setState(() => _loading = false);
    });
  }

  List<CloudFile> _matchingEpisodes(CloudFile file, List<CloudFile> siblings) {
    final current = ParsedMediaName.parse(file.name);
    final title = _normalizedTitle(current.title);
    final values = siblings.where((candidate) {
      final parsed = ParsedMediaName.parse(candidate.name);
      return parsed.isEpisode && _normalizedTitle(parsed.title) == title;
    }).toList();
    if (!values.any((candidate) => candidate.id == file.id)) values.add(file);
    values.sort((a, b) {
      final first = ParsedMediaName.parse(a.name);
      final second = ParsedMediaName.parse(b.name);
      final season = (first.season ?? 1).compareTo(second.season ?? 1);
      if (season != 0) return season;
      return (first.episode ?? 9999).compareTo(second.episode ?? 9999);
    });
    return values;
  }

  String _normalizedTitle(String title) =>
      title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

  List<CloudFile> _matchingSubtitles(CloudFile file, List<CloudFile> siblings) {
    const extensions = {'srt', 'ass', 'ssa', 'sub', 'vtt', 'sup'};
    final title = _normalizedTitle(ParsedMediaName.parse(file.name).title);
    return siblings.where((candidate) {
      final extension = candidate.name.split('.').last.toLowerCase();
      if (!extensions.contains(extension)) return false;
      final candidateTitle = _normalizedTitle(
        ParsedMediaName.parse(candidate.name).title,
      );
      return candidateTitle.contains(title) || title.contains(candidateTitle);
    }).toList();
  }

  Future<void> _setDirectorySubtitle(CloudFile selected) async {
    try {
      final url = await ref.read(fileProvider.notifier).playbackUrl(selected);
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(url.toString(), title: selected.name),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '加载字幕失败：$error');
    }
  }

  Future<void> _searchDirectorySubtitles() async {
    final siblings = await ref
        .read(fileProvider.notifier)
        .siblingFiles(_currentFile);
    if (!mounted) return;
    setState(() {
      _subtitleCandidates = _matchingSubtitles(_currentFile, siblings);
    });
  }

  Future<void> _loadLocalSubtitle() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass', 'ssa', 'sub', 'vtt', 'sup'],
      dialogTitle: '选择外挂字幕',
    );
    final path = result?.files.single.path;
    if (path == null) return;
    await _player.setSubtitleTrack(
      SubtitleTrack.uri(
        Uri.file(path).toString(),
        title: result!.files.single.name,
      ),
    );
  }

  @override
  void dispose() {
    _saveCurrentPlaybackProgress();
    _videoDimensionFallbackTimer?.cancel();
    _videoParamsSubscription?.cancel();
    _positionSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 600;
    final sideWidth = _showEpisodes && !compact ? 250.0 : 0.0;
    final dialogPadding = compact ? 12.0 : 20.0;
    final maxDialogWidth = math.max(1.0, screen.width - 24);
    final maxContentWidth = math.max(1.0, maxDialogWidth - dialogPadding * 2);
    final maxVideoWidth = math.max(1.0, maxContentWidth - sideWidth);
    final minVideoWidth = math.min(compact ? 240.0 : 360.0, maxVideoWidth);
    final minVideoHeight = compact ? 160.0 : 240.0;
    final maxVideoHeight = math.max(
      minVideoHeight,
      screen.height - (compact ? 230 : 290),
    );
    final preferredWidth = _hasVideoDimensions
        ? math.min(900.0, _videoAspectRatio * maxVideoHeight)
        : 600.0;
    final videoWidth = preferredWidth
        .clamp(minVideoWidth, maxVideoWidth)
        .toDouble();
    final videoHeight = (videoWidth / _videoAspectRatio)
        .clamp(minVideoHeight, maxVideoHeight)
        .toDouble();
    final contentWidth = videoWidth + sideWidth;
    return ShadDialog(
      constraints: BoxConstraints(
        maxWidth: math.min(maxDialogWidth, contentWidth + dialogPadding * 2),
        maxHeight: math.max(260, screen.height - 16),
      ),
      padding: EdgeInsets.all(dialogPadding),
      scrollable: false,
      title: Text(
        _currentFile.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      description: const Text('内置播放器'),
      actions: [
        ShadButton.outline(
          onPressed: _episodes.length < 2
              ? null
              : compact
              ? _showEpisodesSheet
              : () => setState(() => _showEpisodes = !_showEpisodes),
          leading: const Icon(Icons.format_list_bulleted_rounded, size: 16),
          child: const Text('同目录剧集'),
        ),
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: contentWidth,
          height: videoHeight,
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ColoredBox(
                    color: Colors.black,
                    child: _loading
                        ? Center(
                            child: AppLoadingIndicator(
                              size: AppLoadingSize.regular,
                              color: cs.primary,
                              label: '正在准备播放',
                            ),
                          )
                        : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                '无法播放：$_error',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: cs.destructive),
                              ),
                            ),
                          )
                        : Video(
                            controller: _controller,
                            controls: (videoState) => _MediaPlaybackControls(
                              player: _player,
                              directorySubtitles: _subtitleCandidates,
                              onSelectDirectorySubtitle: _setDirectorySubtitle,
                              onSearchDirectorySubtitles:
                                  _searchDirectorySubtitles,
                              onLoadLocalSubtitle: _loadLocalSubtitle,
                              onToggleFullscreen: videoState.toggleFullscreen,
                            ),
                          ),
                  ),
                ),
              ),
              if (_showEpisodes) ...[
                const SizedBox(width: 10),
                SizedBox(width: 240, child: _episodeList(cs)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showEpisodesSheet() => showShadSheet<void>(
    context: context,
    side: ShadSheetSide.bottom,
    builder: (_) => ShadSheet(
      constraints: const BoxConstraints(maxHeight: 520),
      title: const Text('同目录剧集'),
      child: SizedBox(
        height: 360,
        child: _episodeList(ShadTheme.of(context).colorScheme),
      ),
    ),
  );

  Widget _episodeList(ShadColorScheme cs) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.border),
      ),
      child: ListView.builder(
        itemCount: _episodes.length,
        itemBuilder: (context, index) {
          final episode = _episodes[index];
          final parsed = ParsedMediaName.parse(episode.name);
          final selected = episode.id == _currentFile.id;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: selected ? null : () => _open(episode),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                color: selected ? cs.primary.withValues(alpha: 0.10) : null,
                child: Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        'S${(parsed.season ?? 1).toString().padLeft(2, '0')}E${(parsed.episode ?? 0).toString().padLeft(2, '0')}',
                        style: TextStyle(fontSize: 11, color: cs.primary),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        episode.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: cs.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MediaPlaybackControls extends StatefulWidget {
  final Player player;
  final List<CloudFile> directorySubtitles;
  final Future<void> Function(CloudFile subtitle) onSelectDirectorySubtitle;
  final Future<void> Function() onSearchDirectorySubtitles;
  final Future<void> Function() onLoadLocalSubtitle;
  final Future<void> Function() onToggleFullscreen;

  const _MediaPlaybackControls({
    required this.player,
    required this.directorySubtitles,
    required this.onSelectDirectorySubtitle,
    required this.onSearchDirectorySubtitles,
    required this.onLoadLocalSubtitle,
    required this.onToggleFullscreen,
  });

  @override
  State<_MediaPlaybackControls> createState() => _MediaPlaybackControlsState();
}

class _MediaPlaybackControlsState extends State<_MediaPlaybackControls> {
  double? _scrubbingValue;
  final _ratePopover = ShadPopoverController();
  final _audioPopover = ShadPopoverController();
  final _subtitlePopover = ShadPopoverController();

  Future<void> _seekBy(int seconds) async {
    final position = widget.player.state.position + Duration(seconds: seconds);
    final duration = widget.player.state.duration;
    final target = position < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && position > duration
              ? duration
              : position);
    await widget.player.seek(target);
  }

  String _trackLabel(dynamic track) {
    if (track.id == 'no') return '关闭';
    if (track.id == 'auto') return '自动';
    final values = [
      track.title,
      track.language,
      track.codec,
    ].whereType<String>().where((value) => value.isNotEmpty).toSet();
    return values.isEmpty ? '轨道 ${track.id}' : values.join(' · ');
  }

  @override
  void dispose() {
    _ratePopover.dispose();
    _audioPopover.dispose();
    _subtitlePopover.dispose();
    super.dispose();
  }

  Widget _rateMenu() {
    return ShadPopover(
      controller: _ratePopover,
      popover: (_) => SizedBox(
        width: 210,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final value in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () async {
                  await widget.player.setRate(value);
                  _ratePopover.hide();
                  if (mounted) setState(() {});
                },
                child: Text('${value}x'),
              ),
          ],
        ),
      ),
      child: _menuButton(
        '${widget.player.state.rate.toStringAsFixed(widget.player.state.rate % 1 == 0 ? 0 : 2)}x',
        () async => _ratePopover.toggle(),
      ),
    );
  }

  Widget _audioMenu() {
    final tracks = widget.player.state.tracks.audio;
    return ShadPopover(
      controller: _audioPopover,
      popover: (_) => _trackPopover<AudioTrack>(
        title: '音轨',
        tracks: tracks,
        selectedID: widget.player.state.track.audio.id,
        onSelect: (track) async {
          await widget.player.setAudioTrack(track);
          _audioPopover.hide();
          if (mounted) setState(() {});
        },
      ),
      child: _menuButton('音轨', () async => _audioPopover.toggle()),
    );
  }

  Widget _subtitleMenu() {
    final tracks = widget.player.state.tracks.subtitle;
    return ShadPopover(
      controller: _subtitlePopover,
      padding: const EdgeInsets.all(8),
      popover: (_) => _subtitlePopoverContent(tracks),
      child: _menuButton('字幕', () async => _subtitlePopover.toggle()),
    );
  }

  Widget _subtitlePopoverContent(List<SubtitleTrack> tracks) {
    final selectedID = widget.player.state.track.subtitle.id;
    final cs = ShadTheme.of(context).colorScheme;
    final itemStyle = TextStyle(fontSize: 13, color: cs.foreground);
    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '字幕',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          if (tracks.isNotEmpty) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  final selected = track.id == selectedID;
                  return ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: selected ? cs.primary : cs.foreground,
                    textStyle: itemStyle,
                    mainAxisAlignment: MainAxisAlignment.start,
                    onPressed: () async {
                      await widget.player.setSubtitleTrack(track);
                      _subtitlePopover.hide();
                      if (mounted) setState(() {});
                    },
                    leading: Icon(
                      selected
                          ? Icons.check_rounded
                          : Icons.closed_caption_rounded,
                      size: 15,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _trackLabel(track),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          if (widget.directorySubtitles.isNotEmpty) ...[
            const Divider(height: 14),
            Text(
              '同目录字幕 (${widget.directorySubtitles.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.mutedForeground,
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.directorySubtitles.length,
                itemBuilder: (context, index) {
                  final subtitle = widget.directorySubtitles[index];
                  return ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: cs.foreground,
                    textStyle: itemStyle,
                    mainAxisAlignment: MainAxisAlignment.start,
                    onPressed: () async {
                      await widget.onSelectDirectorySubtitle(subtitle);
                      _subtitlePopover.hide();
                    },
                    leading: const Icon(Icons.search_rounded, size: 15),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        subtitle.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const Divider(height: 14),
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            foregroundColor: cs.foreground,
            textStyle: itemStyle,
            mainAxisAlignment: MainAxisAlignment.start,
            onPressed: () async {
              await widget.onSearchDirectorySubtitles();
              if (mounted) setState(() {});
            },
            leading: const Icon(Icons.search_rounded, size: 15),
            child: const Text('搜索同目录字幕'),
          ),
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            foregroundColor: cs.foreground,
            textStyle: itemStyle,
            mainAxisAlignment: MainAxisAlignment.start,
            onPressed: () async {
              _subtitlePopover.hide();
              await widget.onLoadLocalSubtitle();
            },
            leading: const Icon(Icons.folder_open_rounded, size: 15),
            child: const Text('加载本地字幕'),
          ),
        ],
      ),
    );
  }

  Widget _trackPopover<T>({
    required String title,
    required List<T> tracks,
    required String selectedID,
    required Future<void> Function(T track) onSelect,
  }) {
    return SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                final selected = (track as dynamic).id == selectedID;
                return ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: () => onSelect(track),
                  leading: Icon(
                    selected ? Icons.check_rounded : Icons.graphic_eq_rounded,
                    size: 15,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _trackLabel(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration = widget.player.state.duration;
        final max = duration.inMilliseconds.toDouble();
        final current = _scrubbingValue ?? position.inMilliseconds.toDouble();
        final value = max <= 0 ? 0.0 : current.clamp(0.0, max);
        final cs = ShadTheme.of(context).colorScheme;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space):
                widget.player.playOrPause,
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _seekBy(-5),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _seekBy(5),
            const SingleActivator(LogicalKeyboardKey.keyF):
                widget.onToggleFullscreen,
          },
          child: Focus(
            autofocus: true,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: widget.onToggleFullscreen,
              onTap: () => widget.player.playOrPause(),
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 28, 12, 10),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xE6000000)],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              activeTrackColor: cs.primary,
                              inactiveTrackColor: Colors.white.withValues(
                                alpha: 0.28,
                              ),
                              thumbColor: cs.primary,
                            ),
                            child: Slider(
                              value: value,
                              min: 0,
                              max: max <= 0 ? 1 : max,
                              onChangeStart: max <= 0
                                  ? null
                                  : (next) =>
                                        setState(() => _scrubbingValue = next),
                              onChanged: max <= 0
                                  ? null
                                  : (next) =>
                                        setState(() => _scrubbingValue = next),
                              onChangeEnd: max <= 0
                                  ? null
                                  : (next) async {
                                      await widget.player.seek(
                                        Duration(milliseconds: next.round()),
                                      );
                                      if (mounted) {
                                        setState(() => _scrubbingValue = null);
                                      }
                                    },
                            ),
                          ),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _controlButton(
                                  widget.player.state.playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  widget.player.playOrPause,
                                ),
                                _controlButton(
                                  Icons.replay_10_rounded,
                                  () => _seekBy(-10),
                                ),
                                _controlButton(
                                  Icons.forward_10_rounded,
                                  () => _seekBy(10),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${_formatTime(position)} / ${_formatTime(duration)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 20),
                                _rateMenu(),
                                _audioMenu(),
                                _subtitleMenu(),
                                _controlButton(
                                  widget.player.state.volume <= 0
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                  () => widget.player.setVolume(
                                    widget.player.state.volume <= 0 ? 100 : 0,
                                  ),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2,
                                      activeTrackColor: Colors.white,
                                      inactiveTrackColor: Colors.white
                                          .withValues(alpha: 0.28),
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: widget.player.state.volume.clamp(
                                        0.0,
                                        100.0,
                                      ),
                                      min: 0,
                                      max: 100,
                                      onChanged: widget.player.setVolume,
                                    ),
                                  ),
                                ),
                                _controlButton(
                                  Icons.fullscreen_rounded,
                                  widget.onToggleFullscreen,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _controlButton(IconData icon, Future<void> Function() onPressed) {
    return IconButton(
      tooltip: '',
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white, size: 23),
    );
  }

  Widget _menuButton(String label, Future<void> Function() onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 36),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  String _formatTime(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class ExternalPlayerDialog extends ConsumerStatefulWidget {
  final CloudFile file;

  const ExternalPlayerDialog({super.key, required this.file});

  @override
  ConsumerState<ExternalPlayerDialog> createState() =>
      _ExternalPlayerDialogState();
}

class _ExternalPlayerDialogState extends ConsumerState<ExternalPlayerDialog> {
  late final Future<List<ExternalPlayer>> _players;

  @override
  void initState() {
    super.initState();
    _players = ref.read(fileProvider.notifier).availableExternalPlayers();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: const Text('选择外部播放器'),
      description: Text(
        widget.file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
      child: SizedBox(
        width: 420,
        child: FutureBuilder<List<ExternalPlayer>>(
          future: _players,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 100,
                child: Center(
                  child: AppLoadingIndicator(
                    size: AppLoadingSize.regular,
                    label: '正在检测可用播放器',
                  ),
                ),
              );
            }
            final players = snapshot.data!;
            if (players.isEmpty) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '未发现支持的外部播放器',
                    style: TextStyle(color: cs.mutedForeground),
                  ),
                  const SizedBox(height: 12),
                  ShadButton.outline(
                    onPressed: () {
                      ref
                          .read(fileProvider.notifier)
                          .playWithExternalPlayer(widget.file);
                      Navigator.of(context).pop();
                    },
                    leading: const Icon(Icons.play_arrow_rounded, size: 16),
                    child: const Text('使用系统默认播放器'),
                  ),
                ],
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final player in players)
                  ShadButton.outline(
                    onPressed: () {
                      ref
                          .read(fileProvider.notifier)
                          .playWithExternalPlayer(widget.file, player);
                      Navigator.of(context).pop();
                    },
                    leading: const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 16,
                    ),
                    child: Text(player.name),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
