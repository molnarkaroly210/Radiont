// lib/api_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;

// A RadioStation modell, ami az API adatait reprezentálja.
class RadioStation {
  final String id;
  final String name;
  final String streamUrl;
  final String imageUrl;
  String nowPlaying;
  bool isFavorite;

  RadioStation({
    required this.id,
    required this.name,
    required this.streamUrl,
    required this.imageUrl,
    this.nowPlaying = "Stream Online",
    this.isFavorite = false,
  });

  factory RadioStation.fromJson(Map<String, dynamic> json) {
    return RadioStation(
      id: json['stationuuid'],
      name: json['name'] ?? 'Unknown Station',
      streamUrl: json['url_resolved'] ?? '',
      imageUrl: (json['favicon'] != null && json['favicon'].isNotEmpty)
          ? json['favicon']
          : 'assets/images/default_radio.png',
    );
  }
}

class RadioBrowserApi {
  // =========================================================================
  // MÓDOSÍTÁS ITT:
  // A korábbi 'synthwave' címke helyett most országkód alapján kérjük le a 
  // 150 legnépszerűbb, működő magyar rádióállomást.
  // =========================================================================
  static const String _baseUrl = 
      "https://de1.api.radio-browser.info/json/stations/bycountrycodeexact/HU?limit=150&order=clickcount&reverse=true&hidebroken=true";

  Future<List<RadioStation>> fetchStations() async {
    try {
      final response = await http.get(Uri.parse(_baseUrl));

      if (response.statusCode == 200) {
        final List<dynamic> jsonData = json.decode(response.body);
        // Kiszűrjük azokat az állomásokat, amelyeknek nincs érvényes stream URL-je.
        return jsonData
            .map((item) => RadioStation.fromJson(item))
            .where((station) => station.streamUrl.startsWith('http'))
            .toList();
      } else {
        print('API hiba: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Hálózati hiba: $e');
      return [];
    }
  }
}