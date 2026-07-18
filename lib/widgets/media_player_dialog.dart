import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/cloud_file.dart';
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
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    Future.microtask(_open);
  }

  Future<void> _open() async {
    try {
      final url = await ref
          .read(fileProvider.notifier)
          .playbackUrl(widget.file);
      await _player.open(Media(url.toString()), play: true);
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
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
    return ShadDialog(
      title: Text(
        widget.file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      description: const Text('内置播放器'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: 960,
        height: 610,
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
                : Video(controller: _controller),
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
