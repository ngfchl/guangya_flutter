import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/logging/app_logger.dart';
import '../models/cloud_file.dart';
import '../providers/file_provider.dart';
import 'app_dialog.dart';
import 'app_loading_indicator.dart';
import 'file_icon.dart';

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

Future<void> showAudioPlayerDialog(
  BuildContext context,
  CloudFile file, {
  List<CloudFile> episodeCandidates = const [],
  VoidCallback? onDownload,
}) async {
  try {
    await showShadDialog<void>(
      context: context,
      builder: (_) => AudioPlayerDialog(
        file: file,
        episodeCandidates: episodeCandidates,
        onDownload: onDownload,
      ),
    );
  } catch (error, stackTrace) {
    AppLogger.warning('AudioPlayer', '音频播放器窗口异常：$error');
    AppLogger.debug('AudioPlayer', stackTrace.toString());
  }
}

class AudioPlayerDialog extends ConsumerStatefulWidget {
  final CloudFile file;
  final List<CloudFile> episodeCandidates;
  final VoidCallback? onDownload;

  const AudioPlayerDialog({
    super.key,
    required this.file,
    this.episodeCandidates = const [],
    this.onDownload,
  });

  @override
  ConsumerState<AudioPlayerDialog> createState() => _AudioPlayerDialogState();
}

class _AudioPlayerDialogState extends ConsumerState<AudioPlayerDialog> {
  late final Player _player;
  late CloudFile _currentFile;
  bool _loading = true;
  String? _error;
  bool _showPlaylist = false;
  List<CloudFile> _playlist = const [];
  int _currentIndex = 0;
  double? _dragPosition;
  double _volume = 1;
  double _rate = 1;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _currentFile = widget.file;
    _buildPlaylist();
    Future.microtask(_open);
  }

  void _buildPlaylist() {
    final candidates = widget.episodeCandidates
        .where((f) => !f.isDirectory && !f.isIso)
        .toList();
    if (candidates.isEmpty) {
      _playlist = [_currentFile];
    } else {
      _playlist = candidates;
      final idx = candidates.indexWhere((f) => f.id == _currentFile.id);
      _currentIndex = idx >= 0 ? idx : 0;
    }
  }

  Future<void> _open([CloudFile? file]) async {
    if (file != null) {
      _currentFile = file;
      _currentIndex = _playlist.indexWhere((f) => f.id == file.id);
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final url = await ref
          .read(fileProvider.notifier)
          .playbackUrl(_currentFile);
      await _player.open(Media(url.toString()), play: true);
      await _player.setVolume(_volume * 100);
      await _player.setRate(_rate);
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      AppLogger.warning('AudioPlayer', '打开音频失败：$error');
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _playPrevious() async {
    if (_currentIndex > 0) {
      _currentIndex--;
      await _open(_playlist[_currentIndex]);
      await _player.play();
    }
  }

  Future<void> _playNext() async {
    if (_currentIndex < _playlist.length - 1) {
      _currentIndex++;
      await _open(_playlist[_currentIndex]);
      await _player.play();
    }
  }

  Future<void> _seekBy(int seconds) async {
    final duration = _player.state.duration;
    final candidate = _player.state.position + Duration(seconds: seconds);
    final target = candidate < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && candidate > duration
        ? duration
        : candidate;
    await _player.seek(target);
  }

  @override
  void dispose() {
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(440.0, screen.width - 24);
    return ShadDialog(
      closeIcon: const SizedBox.shrink(),
      constraints: BoxConstraints(
        maxWidth: dialogWidth,
        maxHeight: screen.height - 48,
      ),
      padding: EdgeInsets.zero,
      scrollable: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(cs),
          _buildTrackInfo(cs),
          _buildControlRow(cs),
          _buildProgressBar(),
          if (_playlist.length > 1) _buildPlaylistSection(cs),
        ],
      ),
    );
  }

  Widget _buildHeader(ShadColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Row(
        children: [
          FileIcon(file: _currentFile, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _currentFile.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.foreground,
              ),
            ),
          ),
          if (widget.onDownload != null)
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: widget.onDownload,
              child: const Icon(LucideIcons.download, size: 15),
            ),
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Icon(LucideIcons.x, size: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackInfo(ShadColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(42, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '${_currentFile.typeName} · ${_currentFile.formattedSize}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: cs.mutedForeground),
        ),
      ),
    );
  }

  Widget _buildControlRow(ShadColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _volume == 0 ? LucideIcons.volumeX : LucideIcons.volume2,
            size: 14,
            color: cs.mutedForeground,
          ),
          SizedBox(
            width: 78,
            child: Material(
              color: Colors.transparent,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 4,
                  ),
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: cs.primary.withValues(alpha: 0.15),
                  thumbColor: cs.primary,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                  overlayColor: cs.primary.withValues(alpha: 0.08),
                ),
                child: Slider(
                  value: _volume,
                  min: 0,
                  max: 1,
                  onChanged: (value) {
                    setState(() => _volume = value);
                    unawaited(_player.setVolume(value * 100));
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _controlButton(
            icon: _playlist.length > 1
                ? LucideIcons.skipBack
                : LucideIcons.rotateCcw,
            tooltip: _playlist.length > 1 ? '上一首' : '后退 10 秒',
            onPressed: () =>
                _playlist.length > 1 ? _playPrevious() : _seekBy(-10),
          ),
          const SizedBox(width: 8),
          StreamBuilder<bool>(
            stream: _player.stream.playing,
            initialData: _player.state.playing,
            builder: (context, snapshot) {
              final playing = snapshot.data ?? false;
              return StreamBuilder<bool>(
                stream: _player.stream.buffering,
                initialData: _player.state.buffering,
                builder: (context, bufferingSnapshot) {
                  final buffering = bufferingSnapshot.data ?? false;
                  return ShadTooltip(
                    builder: (_) => Text(playing ? '暂停' : '播放'),
                    child: ShadButton(
                      size: ShadButtonSize.sm,
                      width: 40,
                      height: 40,
                      padding: EdgeInsets.zero,
                      onPressed: _loading || _error != null
                          ? null
                          : () {
                              if (playing) {
                                _player.pause();
                              } else {
                                _player.play();
                              }
                            },
                      child: buffering
                          ? const AppLoadingIndicator(
                              size: AppLoadingSize.inline,
                              color: Colors.white,
                            )
                          : Icon(
                              playing ? LucideIcons.pause : LucideIcons.play,
                              size: 16,
                              color: cs.primaryForeground,
                            ),
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(width: 8),
          _controlButton(
            icon: _playlist.length > 1
                ? LucideIcons.skipForward
                : LucideIcons.rotateCw,
            tooltip: _playlist.length > 1 ? '下一首' : '前进 10 秒',
            onPressed: () =>
                _playlist.length > 1 ? _playNext() : _seekBy(10),
          ),
          const SizedBox(width: 12),
          ShadSelect<double>(
            minWidth: 48,
            initialValue: _rate,
            decoration: ShadDecoration(
              border: ShadBorder.none,
            ),
            onChanged: (value) {
              if (value == null) return;
              setState(() => _rate = value);
              unawaited(_player.setRate(value));
            },
            selectedOptionBuilder: (_, value) => Text(
              '${value}x',
              style: TextStyle(fontSize: 11, color: cs.mutedForeground),
            ),
            options: const [
              ShadOption(value: 0.5, child: Text('0.5x')),
              ShadOption(value: 0.75, child: Text('0.75x')),
              ShadOption(value: 1.0, child: Text('1.0x')),
              ShadOption(value: 1.25, child: Text('1.25x')),
              ShadOption(value: 1.5, child: Text('1.5x')),
              ShadOption(value: 2.0, child: Text('2.0x')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String tooltip,
    required Future<void> Function() onPressed,
  }) {
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: ShadButton.outline(
        width: 32,
        height: 32,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Icon(icon, size: 14),
      ),
    );
  }

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: StreamBuilder<Duration>(
        stream: _player.stream.duration,
        initialData: _player.state.duration,
        builder: (context, durationSnapshot) {
          final duration = durationSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: _player.stream.position,
            initialData: _player.state.position,
            builder: (context, positionSnapshot) {
              final position = positionSnapshot.data ?? Duration.zero;
              final maxMs = duration.inMilliseconds.toDouble();
              final value =
                  (_dragPosition ?? position.inMilliseconds.toDouble())
                      .clamp(0.0, maxMs > 0 ? maxMs : 1.0);
              final cs = ShadTheme.of(context).colorScheme;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 1,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 3,
                        ),
                        activeTrackColor: cs.primary,
                        inactiveTrackColor: cs.primary.withValues(alpha: 0.15),
                        thumbColor: cs.primary,
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        overlayColor: cs.primary.withValues(alpha: 0.08),
                      ),
                      child: Slider(
                        value: value,
                        min: 0,
                        max: maxMs > 0 ? maxMs : 1,
                        onChangeStart: maxMs > 0
                            ? (next) => setState(() => _dragPosition = next)
                            : null,
                        onChanged: maxMs > 0
                            ? (next) => setState(() => _dragPosition = next)
                            : null,
                        onChangeEnd: maxMs > 0
                            ? (next) async {
                                await _player.seek(
                                  Duration(milliseconds: next.round()),
                                );
                                if (mounted) {
                                  setState(() => _dragPosition = null);
                                }
                              }
                            : null,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(
                            Duration(milliseconds: value.round()),
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                            color: cs.mutedForeground,
                          ),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: TextStyle(
                            fontSize: 11,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPlaylistSection(ShadColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        ShadButton.ghost(
          width: double.infinity,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          onPressed: () => setState(() => _showPlaylist = !_showPlaylist),
          child: Row(
            children: [
              Icon(LucideIcons.listMusic, size: 14, color: cs.mutedForeground),
              const SizedBox(width: 8),
              Text(
                '播放列表 (${_playlist.length})',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.mutedForeground,
                ),
              ),
              const Spacer(),
              Icon(
                _showPlaylist
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
                size: 14,
                color: cs.mutedForeground,
              ),
            ],
          ),
        ),
        if (_showPlaylist)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _playlist.length,
              itemBuilder: (context, index) {
                final item = _playlist[index];
                final isCurrent = index == _currentIndex;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _open(item).then((_) => _player.play()),
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      color: isCurrent
                          ? cs.primary.withValues(alpha: 0.08)
                          : null,
                      child: Row(
                        children: [
                          if (isCurrent)
                            Icon(
                              LucideIcons.music2,
                              size: 13,
                              color: cs.primary,
                            )
                          else
                            Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.mutedForeground,
                              ),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isCurrent ? cs.primary : cs.foreground,
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
          ),
      ],
    );
  }
}
