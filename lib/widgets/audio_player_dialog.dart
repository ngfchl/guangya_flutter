import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/logging/app_logger.dart';
import '../models/cloud_file.dart';
import '../providers/file_provider.dart';
import 'app_dialog.dart';
import 'confirm_dialog.dart';

/// Format a [Duration] to `mm:ss` or `h:mm:ss`.
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Show a full-featured audio player dialog for an audio [file].
Future<void> showAudioPlayerDialog(
  BuildContext context,
  CloudFile file, {
  List<CloudFile> episodeCandidates = const [],
}) async {
  try {
    await showShadDialog<void>(
      context: context,
      builder: (_) => AudioPlayerDialog(
        file: file,
        episodeCandidates: episodeCandidates,
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

  const AudioPlayerDialog({
    super.key,
    required this.file,
    this.episodeCandidates = const [],
  });

  @override
  ConsumerState<AudioPlayerDialog> createState() => _AudioPlayerDialogState();
}

class _AudioPlayerDialogState extends ConsumerState<AudioPlayerDialog> {
  late final AudioPlayer _player;
  late CloudFile _currentFile;
  bool _loading = true;
  String? _error;
  bool _showPlaylist = false;
  List<CloudFile> _playlist = const [];
  int _currentIndex = 0;
  bool _exitConfirmationVisible = false;
  bool _allowExit = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
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
      await _player.setUrl(url.toString());
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

  Future<void> _requestExit() async {
    if (_allowExit || _exitConfirmationVisible || !mounted) return;
    _exitConfirmationVisible = true;
    final wasPlaying = _player.playing;
    if (wasPlaying) await _player.pause();
    if (!mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '退出音频播放？',
      content: '',
      confirmText: '退出',
      cancelText: '继续播放',
    );
    _exitConfirmationVisible = false;
    if (!mounted) return;
    if (confirmed) {
      _allowExit = true;
      Navigator.of(context, rootNavigator: true).pop();
    } else if (wasPlaying) {
      await _player.play();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 600;
    final content = Platform.isMacOS || Platform.isWindows || Platform.isLinux
        ? _buildDesktop(cs, screen, compact)
        : _buildMobile(cs, screen, compact);
    return PopScope<void>(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestExit());
      },
      child: content,
    );
  }

  Widget _buildDesktop(ShadColorScheme cs, Size screen, bool compact) {
    final dialogWidth = math.min(520.0, screen.width - 80);
    return ShadDialog(
      constraints: BoxConstraints(maxWidth: dialogWidth),
      padding: EdgeInsets.zero,
      scrollable: false,
      title: const Text('音频播放器'),
      description: Text(
        _currentFile.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        ShadButton.outline(onPressed: _requestExit, child: const Text('关闭')),
      ],
      child: _buildBody(cs, compact),
    );
  }

  Widget _buildMobile(ShadColorScheme cs, Size screen, bool compact) {
    final dialogWidth = math.min(520.0, screen.width - 32);
    return ShadDialog(
      constraints: BoxConstraints(maxWidth: dialogWidth),
      padding: EdgeInsets.zero,
      scrollable: false,
      title: Text(
        _currentFile.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      description: const Text('音频播放器'),
      actions: [
        ShadButton.outline(onPressed: _requestExit, child: const Text('关闭')),
      ],
      child: _buildBody(cs, compact),
    );
  }

  Widget _buildBody(ShadColorScheme cs, bool compact) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Album art / waveform placeholder ──
        _buildAlbumArt(cs),

        // ── Progress bar ──
        _buildProgressBar(),

        // ── Controls ──
        _buildControls(cs, compact),

        // ── Playlist (if multiple tracks) ──
        if (_playlist.length > 1) _buildPlaylistSection(cs),
      ],
    );
  }

  Widget _buildAlbumArt(ShadColorScheme cs) {
    return Container(
      height: 200,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            cs.primary.withValues(alpha: 0.15),
            cs.background,
          ],
        ),
      ),
      child: Center(
        child: _loading
            ? const CircularProgressIndicator.adaptive()
            : _error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.alertCircle,
                        size: 48,
                        color: cs.destructive,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: cs.destructive),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : Icon(
                    LucideIcons.music,
                    size: 72,
                    color: cs.primary.withValues(alpha: 0.6),
                  ),
      ),
    );
  }

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: StreamBuilder<Duration?>(
        stream: _player.durationStream,
        builder: (context, durationSnapshot) {
          final duration = durationSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, positionSnapshot) {
              final position = positionSnapshot.data ?? Duration.zero;
              final maxMs = duration.inMilliseconds.toDouble();
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: Slider(
                      min: 0,
                      max: maxMs > 0 ? maxMs : 1,
                      value: position.inMilliseconds
                          .toDouble()
                          .clamp(0, maxMs > 0 ? maxMs : 1),
                      onChanged: maxMs > 0
                          ? (v) => _player.seek(
                              Duration(milliseconds: v.toInt()),
                            )
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: TextStyle(
                            fontSize: 12,
                            color: ShadTheme.of(context)
                                .colorScheme
                                .mutedForeground,
                          ),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: TextStyle(
                            fontSize: 12,
                            color: ShadTheme.of(context)
                                .colorScheme
                                .mutedForeground,
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

  Widget _buildControls(ShadColorScheme cs, bool compact) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Previous
          IconButton(
            onPressed: _playlist.length > 1 ? _playPrevious : null,
            icon: const Icon(Icons.skip_previous_rounded),
            iconSize: 32,
            color: cs.foreground,
          ),
          const SizedBox(width: 12),
          // Play/Pause
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snapshot) {
              final playing = snapshot.data?.playing ?? false;
              final processingState =
                  snapshot.data?.processingState ?? ProcessingState.idle;
              final isBuffering = processingState == ProcessingState.buffering ||
                  processingState == ProcessingState.loading;
              return SizedBox(
                width: 64,
                height: 64,
                child: FilledButton(
                  onPressed: _loading || _error != null
                      ? null
                      : () {
                          if (playing) {
                            _player.pause();
                          } else {
                            _player.play();
                          }
                        },
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: isBuffering
                      ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 3,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 36,
                          color: Colors.white,
                        ),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          // Next
          IconButton(
            onPressed: _playlist.length > 1 ? _playNext : null,
            icon: const Icon(Icons.skip_next_rounded),
            iconSize: 32,
            color: cs.foreground,
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistSection(ShadColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(LucideIcons.listMusic, size: 16, color: cs.mutedForeground),
              const SizedBox(width: 8),
              Text(
                '播放列表 (${_playlist.length})',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.mutedForeground,
                ),
              ),
              const Spacer(),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () =>
                    setState(() => _showPlaylist = !_showPlaylist),
                child: Icon(
                  _showPlaylist
                      ? LucideIcons.chevronUp
                      : LucideIcons.chevronDown,
                  size: 16,
                ),
              ),
            ],
          ),
        ),
        if (_showPlaylist)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _playlist.length,
              itemBuilder: (context, index) {
                final item = _playlist[index];
                final isCurrent = index == _currentIndex;
                return ListTile(
                  dense: true,
                  selected: isCurrent,
                  selectedTileColor: cs.primary.withValues(alpha: 0.1),
                  leading: isCurrent
                      ? Icon(
                          Icons.music_note_rounded,
                          size: 20,
                          color: cs.primary,
                        )
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.mutedForeground,
                          ),
                        ),
                  title: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.normal,
                      color: isCurrent ? cs.primary : cs.foreground,
                    ),
                  ),
                  onTap: () => _open(item).then((_) => _player.play()),
                );
              },
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }
}
