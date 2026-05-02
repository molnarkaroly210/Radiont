// lib/api_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'services/dns_service.dart';

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
  static const String _baseUrl = 
      "https://de1.api.radio-browser.info/json/stations/bycountrycodeexact/HU?limit=150&order=clickcount&reverse=true&hidebroken=true";

  Future<List<RadioStation>> fetchStations() async {
    try {
      // Privát DNS feloldás az API szerver számára
      final uri = Uri.parse(_baseUrl);
      await DnsService.resolve(uri.host);

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final List<dynamic> jsonData = json.decode(response.body);
        final uniqueStations = <String, RadioStation>{};
        for (var item in jsonData) {
          final station = RadioStation.fromJson(item);
          if (station.streamUrl.startsWith('http') && !uniqueStations.containsKey(station.id)) {
            uniqueStations[station.id] = station;
          }
        }
        return uniqueStations.values.toList();
      } else {
        debugPrint('API hiba: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      debugPrint('Hálózati hiba: $e');
      return [];
    }
  }
}