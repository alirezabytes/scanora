import 'dart:convert';

class NoteItem {
  final String id;
  final String title;
  final String content;
  final String
      source; // e.g. 'manual', 'image_to_text', 'pdf_reader', 'captcha'
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> tags;

  const NoteItem({
    required this.id,
    required this.title,
    required this.content,
    this.source = 'manual',
    required this.createdAt,
    required this.updatedAt,
    this.tags = const [],
  });

  int get wordCount =>
      content.trim().isEmpty ? 0 : content.trim().split(RegExp(r'\s+')).length;
  int get charCount => content.length;

  NoteItem copyWith({
    String? id,
    String? title,
    String? content,
    String? source,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? tags,
  }) {
    return NoteItem(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'source': source,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'tags': tags,
    };
  }

  factory NoteItem.fromMap(Map<String, dynamic> map) {
    return NoteItem(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      content: map['content']?.toString() ?? '',
      source: map['source']?.toString() ?? 'manual',
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: map['updatedAt'] != null
          ? DateTime.tryParse(map['updatedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      tags:
          (map['tags'] as List?)?.map((t) => t.toString()).toList() ?? const [],
    );
  }

  String toJson() => jsonEncode(toMap());
  factory NoteItem.fromJson(String source) =>
      NoteItem.fromMap(jsonDecode(source));
}
