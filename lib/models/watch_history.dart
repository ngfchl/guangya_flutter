class WatchHistoryEntry {
  final String fileID;
  final int positionMilliseconds;
  final int durationMilliseconds;
  final DateTime updatedAt;
  final bool completed;

  const WatchHistoryEntry({
    required this.fileID,
    required this.positionMilliseconds,
    required this.durationMilliseconds,
    required this.updatedAt,
    required this.completed,
  });

  double get progress {
    if (durationMilliseconds <= 0) return 0;
    return (positionMilliseconds / durationMilliseconds).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'fileID': fileID,
    'positionMilliseconds': positionMilliseconds,
    'durationMilliseconds': durationMilliseconds,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'completed': completed,
  };

  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) {
    return WatchHistoryEntry(
      fileID: json['fileID']?.toString() ?? '',
      positionMilliseconds:
          int.tryParse(json['positionMilliseconds']?.toString() ?? '') ?? 0,
      durationMilliseconds:
          int.tryParse(json['durationMilliseconds']?.toString() ?? '') ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse(json['updatedAt']?.toString() ?? '') ?? 0,
      ),
      completed: json['completed'] == true,
    );
  }
}
