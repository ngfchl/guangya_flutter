/// Byte-size formatting utility shared across the entire app.
class FormatBytes {
  const FormatBytes._();

  /// Format [bytes] into a human-readable string.
  ///
  /// ```
  /// FormatBytes.format(1536)       // => '1.5 KB'
  /// FormatBytes.format(1073741824) // => '1.0 GB'
  /// ```
  static String format(int bytes, {int fractionDigits = 1}) {
    if (bytes < 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(fractionDigits)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(fractionDigits)} MB';
    }
    if (bytes < 1024 * 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(fractionDigits)} GB';
    }
    if (bytes < 1024 * 1024 * 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(2)} TB';
    }
    return '${(bytes / (1024 * 1024 * 1024 * 1024 * 1024)).toStringAsFixed(2)} PB';
  }
}
