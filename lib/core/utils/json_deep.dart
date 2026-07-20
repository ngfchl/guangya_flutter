/// Shared helpers for recursively extracting values from nested JSON maps.
///
/// The cloud-drive API returns inconsistent shapes across endpoints; these
/// utilities normalise the "find first matching key deep in the tree" pattern
/// that was previously copy-pasted into five-plus files.
class JsonDeep {
  const JsonDeep._();

  // ── String ──────────────────────────────────────────────────────────

  /// Walk [json] looking for any of [keys] at any nesting depth.
  /// Returns the first non-null, non-empty string found, or `null`.
  static String? findString(dynamic json, List<String> keys) =>
      _find<String>(json, keys, (value) {
        if (value == null) return null;
        final text = value.toString().trim();
        return text.isEmpty ? null : text;
      });

  // ── int ─────────────────────────────────────────────────────────────

  static int? findInt(dynamic json, List<String> keys) =>
      _find<int>(json, keys, (value) {
        if (value is int) return value;
        return value == null ? null : int.tryParse(value.toString());
      });

  // ── bool ────────────────────────────────────────────────────────────

  static bool? findBool(dynamic json, List<String> keys) =>
      _find<bool>(json, keys, (value) {
        if (value is bool) return value;
        if (value != null) {
          final text = value.toString().toLowerCase();
          if (text == 'true' || text == '1') return true;
          if (text == 'false' || text == '0') return false;
        }
        return null;
      });

  // ── Map ─────────────────────────────────────────────────────────────

  static Map<String, dynamic>? findMap(dynamic json, List<String> keys) =>
      _find<Map<String, dynamic>>(
        json,
        keys,
        (value) => value is Map ? Map<String, dynamic>.from(value) : null,
      );

  // ── List / Array ────────────────────────────────────────────────────

  /// Search [json] for the first list under any of [keys], searching
  /// `data`, `result`, `payload` wrappers first, then all other entries.
  static List<dynamic>? findArray(dynamic json, List<String> keys) =>
      _find<List<dynamic>>(json, keys, (value) => value is List ? value : null);

  static T? _find<T>(
    dynamic value,
    List<String> keys,
    T? Function(dynamic value) convert,
  ) {
    if (value is Map) {
      for (final key in keys) {
        if (!value.containsKey(key)) continue;
        final converted = convert(value[key]);
        if (converted != null) return converted;
      }
      for (final child in value.values) {
        final found = _find<T>(child, keys, convert);
        if (found != null) return found;
      }
    } else if (value is Iterable && value is! String) {
      for (final child in value) {
        final found = _find<T>(child, keys, convert);
        if (found != null) return found;
      }
    }
    return null;
  }
}
