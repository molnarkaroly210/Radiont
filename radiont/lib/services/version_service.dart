import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class VersionService {
  static const String repoOwner = "molnarkaroly210";
  static const String repoName = "Radiont";
  static const String githubApiUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest";

  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      // 1. Lekérjük a jelenlegi verziót
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // 2. Lekérjük a legfrissebb verziót a GitHubról
      final response = await http.get(Uri.parse(githubApiUrl));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final latestVersion = (data['tag_name'] as String).replaceAll('v', '');
        final downloadUrl = data['html_url'] as String;

        // 3. Összehasonlítás (egyszerű string alapú, de lehetne szemantikus is)
        if (_isNewer(latestVersion, currentVersion)) {
          if (context.mounted) {
            _showUpdateDialog(context, currentVersion, latestVersion, downloadUrl);
          }
        }
      }
    } catch (e) {
      debugPrint("Verzióellenőrzési hiba: $e");
    }
  }

  // Szemantikus verzió összehasonlítás (pl. 1.0.1 > 1.0.0)
  static bool _isNewer(String latest, String current) {
    List<int> latestParts = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    List<int> currentParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (int i = 0; i < latestParts.length; i++) {
      if (i >= currentParts.length) return true;
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }
    return false;
  }

  static void _showUpdateDialog(BuildContext context, String current, String latest, String url) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.system_update_rounded, color: Colors.blue),
            SizedBox(width: 10),
            Text("Frissítés elérhető!"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Új verzió érhető el a GitHubon."),
            const SizedBox(height: 10),
            Text("Jelenlegi: v$current", style: const TextStyle(color: Colors.grey)),
            Text("Legfrissebb: v$latest", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Később", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text("Letöltés"),
          ),
        ],
      ),
    );
  }
}
