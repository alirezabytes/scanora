class BookmarkItem {
  final String id;
  final String documentName;
  final int pageNumber;
  final String label;
  final String snippet;
  final DateTime createdAt;

  BookmarkItem({
    required this.id,
    required this.documentName,
    required this.pageNumber,
    required this.label,
    required this.snippet,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentName': documentName,
        'pageNumber': pageNumber,
        'label': label,
        'snippet': snippet,
        'createdAt': createdAt.toIso8601String(),
      };

  factory BookmarkItem.fromJson(Map<String, dynamic> json) => BookmarkItem(
        id: json['id'] as String? ?? '',
        documentName: json['documentName'] as String? ?? '',
        pageNumber: json['pageNumber'] as int? ?? 1,
        label: json['label'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'] as String)
            : null,
      );
}
