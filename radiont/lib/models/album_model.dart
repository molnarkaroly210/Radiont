// lib/models/album_model.dart
//
// Egyéni album (lejátszási lista) modell.
// SharedPreferences-ben JSON-ként perzisztálva.

import 'dart:convert';

class Album {
  final String id;
  String name;
  List<int> songIds;
  double hue; // 0–360, HSV színkör

  Album({
    required this.id,
    required this.name,
    List<int>? songIds,
    this.hue = 200,
  }) : songIds = songIds ?? [];

  /// Album színe a hue értékből
  /// Használat: HSVColor.fromAHSV(1.0, album.hue, 0.7, 0.9).toColor()

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songIds': songIds,
    'hue': hue,
  };

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: json['id'] as String,
    name: json['name'] as String,
    songIds: (json['songIds'] as List<dynamic>).map((e) => e as int).toList(),
    hue: (json['hue'] as num?)?.toDouble() ?? 200,
  );

  /// JSON lista → Album lista
  static List<Album> listFromJson(String jsonString) {
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list.map((e) => Album.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Album lista → JSON string
  static String listToJson(List<Album> albums) {
    return jsonEncode(albums.map((a) => a.toJson()).toList());
  }
}
