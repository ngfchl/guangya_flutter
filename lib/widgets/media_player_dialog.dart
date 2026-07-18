import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../providers/file_provider.dart';

class MediaPlayerDialog extends ConsumerStatefulWidget {
  final CloudFile file;

  const MediaPlayerDialog({super.key, required this.file});

  @override
  ConsumerState<MediaPlayerDialog> createState() => _MediaPlayerDialogState();
}

class _MediaPlayerDialogState extends ConsumerState<MediaPlayerDialog> {
  late final Player _player;
  late final VideoController _controller;
  final _videoKey = GlobalKey<VideoState>();
  late CloudFile _currentFile;
  String? _error;
  bool _loading = true;
  bool _showEpisodes = false;
  List<CloudFile> _episodes = const [];
  List<CloudFile> _subtitleCandidates = const [];

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _currentFile = widget.file;
    Future.microtask(_open);
  }

  Future<void> _open([CloudFile? file]) async {
    if (file != null && mounted) {
      setState(() {
        _currentFile = file;
        _loading = true;
        _error = null;
      });
    }
    try {
      final url = await ref
          .read(fileProvider.notifier)
          .playbackUrl(_currentFile);
      await _player.open(Media(url.toString()), play: true);
      final siblings = await ref
          .read(fileProvider.notifier)
          .siblingMediaFiles(_currentFile);
      _episodes = _matchingEpisodes(_currentFile, siblings);
      final folderFiles = await ref
          .read(fileProvider.notifier)
          .siblingFiles(_currentFile);
      _subtitleCandidates = _matchingSubtitles(_currentFile, folderFiles);
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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

  Future<void> _searchDirectorySubtitles() async {
    if (_subtitleCandidates.isEmpty) {
      await showShadDialog<void>(
        context: context,
        builder: (context) => const ShadDialog(
          title: Text('同目录字幕'),
          description: Text('缓存的当前目录中没有找到匹配的字幕文件。'),
        ),
      );
      return;
    }
    final selected = await showShadDialog<CloudFile>(
      context: context,
      builder: (context) => _SubtitlePickerDialog(
        title: '同目录字幕 (${_subtitleCandidates.length})',
        subtitles: _subtitleCandidates,
      ),
    );
    if (selected == null || !mounted) return;
    try {
      final url = await ref.read(fileProvider.notifier).playbackUrl(selected);
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(url.toString(), title: selected.name),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '加载字幕失败：$error');
    }
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
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
          width: 960,
          height: 610,
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ColoredBox(
                    color: Colors.black,
                    child: _loading
                        ? const Center(child: ShadProgress())
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
                        : Stack(
                            children: [
                              Positioned.fill(
                                child: Video(
                                  key: _videoKey,
                                  controller: _controller,
                                  controls: NoVideoControls,
                                ),
                              ),
                              Positioned.fill(
                                child: _MediaPlaybackControls(
                                  player: _player,
                                  controller: _controller,
                                  onSearchSubtitles: _searchDirectorySubtitles,
                                  onLoadLocalSubtitle: _loadLocalSubtitle,
                                  onToggleFullscreen: () =>
                                      _videoKey.currentState
                                          ?.toggleFullscreen() ??
                                      Future.value(),
                                ),
                              ),
                            ],
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
  final VideoController controller;
  final Future<void> Function() onSearchSubtitles;
  final Future<void> Function() onLoadLocalSubtitle;
  final Future<void> Function() onToggleFullscreen;

  const _MediaPlaybackControls({
    required this.player,
    required this.controller,
    required this.onSearchSubtitles,
    required this.onLoadLocalSubtitle,
    required this.onToggleFullscreen,
  });

  @override
  State<_MediaPlaybackControls> createState() => _MediaPlaybackControlsState();
}

class _MediaPlaybackControlsState extends State<_MediaPlaybackControls> {
  double? _scrubbingValue;

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

  Future<void> _selectRate() async {
    final rate = await showShadDialog<double>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('播放速度'),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
              ShadButton.outline(
                onPressed: () => Navigator.of(context).pop(value),
                child: Text('${value}x'),
              ),
          ],
        ),
      ),
    );
    if (rate != null) await widget.player.setRate(rate);
  }

  Future<void> _selectAudio() async {
    final tracks = widget.player.state.tracks.audio;
    final track = await showShadDialog<AudioTrack>(
      context: context,
      builder: (context) => _TrackPickerDialog<AudioTrack>(
        title: '选择音轨',
        tracks: tracks,
        selectedID: widget.player.state.track.audio.id,
        label: _trackLabel,
        id: (track) => track.id,
      ),
    );
    if (track != null) await widget.player.setAudioTrack(track);
  }

  Future<void> _selectSubtitle() async {
    final tracks = widget.player.state.tracks.subtitle;
    final track = await showShadDialog<SubtitleTrack>(
      context: context,
      builder: (context) => _TrackPickerDialog<SubtitleTrack>(
        title: '选择字幕',
        tracks: tracks,
        selectedID: widget.player.state.track.subtitle.id,
        label: _trackLabel,
        id: (track) => track.id,
      ),
    );
    if (track != null) await widget.player.setSubtitleTrack(track);
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
                                _menuButton(
                                  '${widget.player.state.rate.toStringAsFixed(widget.player.state.rate % 1 == 0 ? 0 : 2)}x',
                                  _selectRate,
                                ),
                                _menuButton('音轨', _selectAudio),
                                _menuButton('字幕', _selectSubtitle),
                                _menuButton('搜字幕', widget.onSearchSubtitles),
                                _menuButton('加载字幕', widget.onLoadLocalSubtitle),
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

class _TrackPickerDialog<T> extends StatelessWidget {
  final String title;
  final List<T> tracks;
  final String selectedID;
  final String Function(T track) label;
  final String Function(T track) id;

  const _TrackPickerDialog({
    required this.title,
    required this.tracks,
    required this.selectedID,
    required this.label,
    required this.id,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: Text(title),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final track in tracks)
                ListTile(
                  onTap: () => Navigator.of(context).pop(track),
                  title: Text(label(track)),
                  trailing: id(track) == selectedID
                      ? Icon(Icons.check_rounded, color: cs.primary)
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubtitlePickerDialog extends StatelessWidget {
  final String title;
  final List<CloudFile> subtitles;

  const _SubtitlePickerDialog({required this.title, required this.subtitles});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: Text(title),
      description: const Text('从当前视频同目录的缓存文件中匹配'),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 520,
          height: 360,
          child: ListView.separated(
            itemCount: subtitles.length,
            separatorBuilder: (_, _) => Divider(height: 1, color: cs.border),
            itemBuilder: (context, index) {
              final subtitle = subtitles[index];
              return ListTile(
                onTap: () => Navigator.of(context).pop(subtitle),
                leading: Icon(Icons.closed_caption_rounded, color: cs.primary),
                title: Text(
                  subtitle.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(subtitle.formattedSize),
              );
            },
          ),
        ),
      ),
    );
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
                child: Center(child: ShadProgress()),
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
