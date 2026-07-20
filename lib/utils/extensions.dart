import '../core/utils/format_bytes.dart';

extension StringExtensions on String {
  String truncate(int maxLen) {
    if (length <= maxLen) return this;
    return '${substring(0, maxLen)}…';
  }
}

extension IntExtensions on int {
  String get formattedBytes => FormatBytes.format(this);
}
