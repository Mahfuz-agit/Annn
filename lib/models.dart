class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    required this.uri,
    required this.remote,
    this.date,
  });

  final String id;
  final String title;
  final String uri;
  final bool remote;
  final DateTime? date;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'uri': uri,
        'remote': remote,
        'date': date?.toIso8601String(),
      };

  factory VideoItem.fromJson(Map<String, dynamic> j) => VideoItem(
        id: j['id'] as String,
        title: j['title'] as String,
        uri: j['uri'] as String,
        remote: (j['remote'] as bool?) ?? true,
        date: j['date'] == null ? null : DateTime.tryParse(j['date'] as String),
      );

  /// "1 year ago today" style label for resurfaced memories.
  String? get memoryLabel {
    final d = date;
    if (d == null) return null;
    final n = DateTime.now();
    if (d.month == n.month && d.day == n.day && d.year < n.year) {
      final y = n.year - d.year;
      return y == 1 ? '1 year ago today' : '$y years ago today';
    }
    return null;
  }
}
