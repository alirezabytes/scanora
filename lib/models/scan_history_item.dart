enum ScanType {
  captcha,
  document,
  pdf,
  query,
}

class ScanHistoryItem {
  final String id;
  final ScanType type;
  final String title;
  final String content;
  final bool isOffline;
  final String? modelOrEngine;
  final DateTime timestamp;
  final String? sourcePath;
  final int startPage;
  final int endPage;

  ScanHistoryItem({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.isOffline,
    this.modelOrEngine,
    this.sourcePath,
    this.startPage = 1,
    this.endPage = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'content': content,
        'isOffline': isOffline,
        'modelOrEngine': modelOrEngine,
        'timestamp': timestamp.toIso8601String(),
        if (sourcePath != null) ...{
          'sourcePath': sourcePath,
          'startPage': startPage,
          'endPage': endPage,
        },
      };

  factory ScanHistoryItem.fromJson(Map<String, dynamic> json) =>
      ScanHistoryItem(
        id: json['id'] as String,
        type: ScanType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => ScanType.document,
        ),
        title: json['title'] as String,
        content: json['content'] as String,
        isOffline: json['isOffline'] as bool? ?? false,
        modelOrEngine: json['modelOrEngine'] as String?,
        sourcePath: json['sourcePath'] as String?,
        startPage: json['startPage'] as int? ?? 1,
        endPage: json['endPage'] as int? ?? 0,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );
}
