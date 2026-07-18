extension StringExtensions on String {
  String truncate(int maxLen) {
    if (length <= maxLen) return this;
    return '${substring(0, maxLen)}…';
  }
}

extension IntExtensions on int {
  String get formattedBytes {
    if (this < 1024) return '$this B';
    if (this < 1024 * 1024) {
      return '${(this / 1024).toStringAsFixed(1)} KB';
    }
    if (this < 1024 * 1024 * 1024) {
      return '${(this / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(this / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
