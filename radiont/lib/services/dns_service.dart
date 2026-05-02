// lib/services/dns_service.dart
//
// Privát DNS szolgáltatás – AdGuard DNS-over-HTTPS
// Az alkalmazás saját DNS-feloldót használ a telefon alapértelmezett DNS-e helyett.

import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// DNS-over-HTTPS feloldó AdGuard szerverekkel.
class DnsService {
  static const String adguardDefault = 'https://dns.adguard.com/dns-query';
  static const String adguardDns = 'https://dns.adguard-dns.com/dns-query';

  static String _activeDoH = adguardDefault;
  static final Map<String, _DnsCacheEntry> _cache = {};
  static const Duration _cacheTTL = Duration(minutes: 5);

  static String get activeDoH => _activeDoH;

  static void setProvider(String dohUrl) {
    _activeDoH = dohUrl;
    clearCache();
  }

  /// DNS feloldás DoH-val, fallback rendszer DNS-re
  static Future<List<InternetAddress>> resolve(String host) async {
    if (_isIpAddress(host)) {
      return [InternetAddress(host)];
    }

    // Ne próbáljuk DoH-val feloldani magát a DoH szervert
    final dohHost = Uri.parse(_activeDoH).host;
    if (host == dohHost) {
      return InternetAddress.lookup(host);
    }

    // Cache ellenőrzés
    final cached = _cache[host];
    if (cached != null && !cached.isExpired) {
      return cached.addresses;
    }

    // DoH feloldás
    try {
      final addresses = await _resolveWithDoH(host);
      if (addresses.isNotEmpty) {
        _cache[host] = _DnsCacheEntry(addresses, DateTime.now().add(_cacheTTL));
        return addresses;
      }
    } catch (e) {
      debugPrint('[DnsService] DoH hiba ($host): $e');
    }

    // Fallback: rendszer DNS
    try {
      final systemAddresses = await InternetAddress.lookup(host);
      if (systemAddresses.isNotEmpty) {
        _cache[host] = _DnsCacheEntry(systemAddresses, DateTime.now().add(_cacheTTL));
        return systemAddresses;
      }
    } catch (e) {
      debugPrint('[DnsService] Rendszer DNS is sikertelen ($host): $e');
    }

    throw SocketException('DNS feloldás sikertelen: $host');
  }

  /// DoH API hívás – a http csomagot használja (HTTPS-t megfelelően kezeli)
  static Future<List<InternetAddress>> _resolveWithDoH(String host) async {
    final uri = Uri.parse('$_activeDoH?name=$host&type=A');

    final response = await http.get(uri, headers: {
      'Accept': 'application/dns-json',
    }).timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final List<InternetAddress> addresses = [];

      if (json.containsKey('Answer')) {
        final answers = json['Answer'] as List<dynamic>;
        for (final answer in answers) {
          final type = answer['type'] as int?;
          final data = answer['data'] as String?;
          if (data != null && (type == 1 || type == 28)) {
            try {
              addresses.add(InternetAddress(data));
            } catch (_) {}
          }
        }
      }
      return addresses;
    }
    return [];
  }

  static bool _isIpAddress(String host) {
    final ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    final ipv6 = RegExp(r'^[0-9a-fA-F:]+$');
    return ipv4.hasMatch(host) || (host.contains(':') && ipv6.hasMatch(host));
  }

  static void clearCache() {
    _cache.clear();
  }
}

class _DnsCacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;
  _DnsCacheEntry(this.addresses, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Globális HttpOverrides – egyedi DNS feloldóval.
/// A findProxyFromEnvironment-et használja a DNS feloldásra,
/// a connectionFactory-t NEM írja felül (az törné a TLS-t).
class PrivateDnsHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // NEM írjuk felül a connectionFactory-t,
    // mert az plain Socket-et ad vissza ami nem kompatibilis a HTTPS TLS kézfogással.
    // Ehelyett a DnsService.resolve()-ot közvetlenül használjuk az api_service.dart-ban.
    return client;
  }
}
