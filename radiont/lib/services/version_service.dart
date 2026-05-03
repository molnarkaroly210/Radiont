import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:confetti/confetti.dart';

class VersionService {
  static const String repoOwner = "molnarkaroly210";
  static const String repoName = "Radiont";
  static const String githubApiUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest";
  static const _platform = MethodChannel('com.example.radiont/media_manager');

  // Tárolt frissítési adatok (a TopBar használja)
  static bool updateAvailable = false;
  static String _currentVersion = '';
  static String _latestVersion = '';
  static String? _apkUrl;
  static String _fallbackUrl = '';
  static String _releaseNotes = '';
  static DateTime _publishedAt = DateTime.now();


  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await http.get(Uri.parse(githubApiUrl));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final latestVersion = (data['tag_name'] as String).replaceAll('v', '');

        // APK keresése az assetek között
        String? apkDownloadUrl;
        final assets = data['assets'] as List?;
        if (assets != null) {
          for (var asset in assets) {
            if ((asset['name'] as String).endsWith('.apk')) {
              apkDownloadUrl = asset['browser_download_url'];
              break;
            }
          }
        }

        final fallbackUrl = data['html_url'] as String;
        final releaseNotes = data['body'] as String? ?? "Nincs megadva leírás.";
        final publishedAt = DateTime.parse(data['published_at']);

        if (_isNewer(latestVersion, currentVersion)) {
          // Eltároljuk az adatokat
          updateAvailable = true;
          _currentVersion = currentVersion;
          _latestVersion = latestVersion;
          _apkUrl = apkDownloadUrl;
          _fallbackUrl = fallbackUrl;
          _releaseNotes = releaseNotes;
          _publishedAt = publishedAt;

          if (context.mounted) {
            _showUpdateDialog(context, currentVersion, latestVersion, apkDownloadUrl, fallbackUrl, releaseNotes, publishedAt);
          }
        }
      }
    } catch (e) {
      debugPrint("Verzióellenőrzési hiba: $e");
    }
  }

  /// Publikus metódus: a TopBar-ból hívható, megnyitja a frissítési ablakot
  static void showUpdate(BuildContext context) {
    if (updateAvailable) {
      _showUpdateDialog(context, _currentVersion, _latestVersion, _apkUrl, _fallbackUrl, _releaseNotes, _publishedAt);
    }
  }


  static String _getTimeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inDays > 0) return "${diff.inDays} napja";
    if (diff.inHours > 0) return "${diff.inHours} órája";
    if (diff.inMinutes > 0) return "${diff.inMinutes} perce";
    return "Most érkezett";
  }

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

  static void _showUpdateDialog(
    BuildContext context, String current, String latest,
    String? apkUrl, String fallbackUrl, String notes, DateTime publishedAt,
  ) {
    final confettiController = ConfettiController(duration: const Duration(seconds: 3));
    double downloadProgress = 0;
    bool isDownloading = false;
    String statusText = "Frissítés most";

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Stack(
          alignment: Alignment.topCenter,
          children: [
            AlertDialog(
              backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
              title: Row(
                children: [
                  const Icon(Icons.system_update_rounded, color: Colors.blue, size: 28),
                  const SizedBox(width: 12),
                  const Expanded(child: Text("Frissítés elérhető!")),
                  Text(_getTimeAgo(publishedAt), style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Új verzió érhető el a GitHubon."),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text("v$current", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      const Icon(Icons.arrow_right_alt_rounded, color: Colors.grey, size: 16),
                      Text("v$latest", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 13)),
                    ],
                  ),
                  const Divider(height: 30),
                  const Text("Újdonságok:", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      child: Text(notes, style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4)),
                    ),
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 20),
                    LinearProgressIndicator(
                      value: downloadProgress,
                      borderRadius: BorderRadius.circular(10),
                      backgroundColor: Colors.grey[800],
                      color: Colors.blue,
                    ),
                    const SizedBox(height: 5),
                    Center(child: Text(
                      "${(downloadProgress * 100).toInt()}%",
                      style: const TextStyle(fontSize: 10, color: Colors.blue),
                    )),
                  ],
                ],
              ),
              actions: [
                if (!isDownloading)
                  TextButton(
                    onPressed: () {
                      confettiController.dispose();
                      Navigator.pop(context);
                    },
                    child: const Text("Mégse", style: TextStyle(color: Colors.grey)),
                  ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: isDownloading ? null : () async {
                    if (apkUrl != null) {
                      // Alkalmazáson belüli letöltés + telepítés
                      setState(() {
                        isDownloading = true;
                        statusText = "Letöltés...";
                      });
                      final success = await _downloadAndInstall(
                        apkUrl,
                        (progress) => setState(() => downloadProgress = progress),
                        context,
                      );
                      if (success) {
                        confettiController.play();
                        await Future.delayed(const Duration(milliseconds: 800));
                      }
                      // Azonnal bezárjuk az ablakot, hogy ne akadjon meg
                      // amikor az Android átirányít a Beállításokba
                      if (context.mounted) {
                        confettiController.dispose();
                        Navigator.pop(context);
                      }
                    } else {
                      confettiController.dispose();
                      if (context.mounted) Navigator.pop(context);
                      await launchUrl(Uri.parse(fallbackUrl), mode: LaunchMode.externalApplication);
                    }
                  },

                  child: Text(statusText),
                ),
              ],
            ),
            ConfettiWidget(
              confettiController: confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              colors: const [Colors.green, Colors.blue, Colors.pink, Colors.orange, Colors.purple],
            ),
          ],
        ),
      ),
    );
  }

  static Future<bool> _downloadAndInstall(String url, Function(double) onProgress, BuildContext context) async {
    try {
      final dio = Dio();
      final tempDir = await getTemporaryDirectory();
      final savePath = "${tempDir.path}/radiont_update.apk";

      debugPrint("APK letöltés indítása: $url");
      debugPrint("Mentés ide: $savePath");

      await dio.download(
        url,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) onProgress(received / total);
        },
      );

      // Ellenőrizzük hogy a fájl tényleg létrejött-e
      final file = File(savePath);
      if (!await file.exists()) {
        debugPrint("HIBA: A letöltött fájl nem létezik: $savePath");
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Hiba: A letöltött fájl nem található.")),
          );
        }
        return false;
      }

      final fileSize = await file.length();
      debugPrint("Fájl mérete: ${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB");

      if (fileSize < 1000000) { // Kevesebb mint 1 MB — valószínűleg hibás fájl
        debugPrint("HIBA: A fájl túl kicsi, valószínűleg nem APK.");
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Hiba: A letöltött fájl hibás. Próbáld újra.")),
          );
        }
        return false;
      }

      // Natív Android telepítő indítása
      debugPrint("Telepítő indítása...");
      await _platform.invokeMethod('installApk', {'filePath': savePath});
      debugPrint("Telepítő sikeresen elindítva!");
      return true;
    } on PlatformException catch (e) {
      debugPrint("Platform hiba a telepítésnél: ${e.code} - ${e.message}");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Telepítési hiba: ${e.message}\nEngedd be a Beállításokban: Ismeretlen alkalmazások telepítése.")),
        );
      }
      return false;
    } catch (e) {
      debugPrint("Letöltési/telepítési hiba: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Hiba: $e")),
        );
      }
      return false;
    }
  }
}

