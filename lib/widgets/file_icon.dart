import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/cloud_file.dart';

class FileIcon extends StatelessWidget {
  final CloudFile file;
  final double size;

  const FileIcon({super.key, required this.file, this.size = 28});

  @override
  Widget build(BuildContext context) {
    if (file.fileType == 8 && file.shareIsDirectory == true) {
      return Icon(
        LucideIcons.folder,
        size: size,
        color: const Color(0xFFF59E0B),
      );
    }
    if (file.isDirectory) {
      return Icon(
        LucideIcons.folder,
        size: size,
        color: const Color(0xFFF59E0B),
      );
    }

    final iconData = file.isAudio
        ? LucideIcons.music
        : _getIconForFileType(file.fileType);
    final color = file.isAudio
        ? const Color(0xFFF59E0B)
        : _getColorForFileType(file.fileType);

    return Icon(iconData, size: size, color: color);
  }

  IconData _getIconForFileType(int fileType) {
    switch (fileType) {
      case 1:
        return LucideIcons.image;
      case 2:
        return LucideIcons.film;
      case 3:
        return LucideIcons.music;
      case 4:
        return LucideIcons.fileText;
      case 5:
      case 9:
        return LucideIcons.archive;
      case 8:
        return LucideIcons.share2;
      default:
        return LucideIcons.file;
    }
  }

  Color _getColorForFileType(int fileType) {
    switch (fileType) {
      case 1:
        return const Color(0xFF10B981);
      case 2:
        return const Color(0xFF3B82F6);
      case 3:
        return const Color(0xFFF59E0B);
      case 4:
        return const Color(0xFF8B5CF6);
      case 5:
      case 9:
        return const Color(0xFF6B7280);
      case 8:
        return const Color(0xFF0EA5E9);
      default:
        return const Color(0xFF6B7280);
    }
  }
}
