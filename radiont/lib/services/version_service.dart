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
  static double _apkSizeMB = 60.0;
  static String _fallbackUrl = '';
  static String _releaseNotes = '';
  static DateTime _publishedAt = DateTime.now();

  // Háttérben történő letöltés adatai
  static final ValueNotifier<bool> isDownloading = ValueNotifier(false);
  static final ValueNotifier<bool> isDownloadReady = ValueNotifier(false);
  static String? downloadedFilePath;
  static final ValueNotifier<double> downloadProgress = ValueNotifier(0.0);


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
        double apkSize = 60.0;
        final assets = data['assets'] as List?;
        if (assets != null) {
          for (var asset in assets) {
            if ((asset['name'] as String).endsWith('.apk')) {
              apkDownloadUrl = asset['browser_download_url'];
              if (asset['size'] != null) {
                apkSize = (asset['size'] as int) / (1024 * 1024);
              }
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
          _apkSizeMB = apkSize;
          _fallbackUrl = fallbackUrl;
          _releaseNotes = releaseNotes;
          _publishedAt = publishedAt;

          if (context.mounted) {
            _showUpdateDialog(context, currentVersion, latestVersion, apkDownloadUrl, apkSize, fallbackUrl, releaseNotes, publishedAt);
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
      _showUpdateDialog(context, _currentVersion, _latestVersion, _apkUrl, _apkSizeMB, _fallbackUrl, _releaseNotes, _publishedAt);
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

  static Future<void> _showUpdateDialog(
    BuildContext context, String current, String latest,
    String? apkUrl, double apkSizeMB, String fallbackUrl, String notes, DateTime publishedAt,
  ) async {
    int? freeSpaceBytes;
    bool hasEnoughSpace = true;

    try {
      freeSpaceBytes = await _platform.invokeMethod<int>('getFreeSpace');
      if (freeSpaceBytes != null) {
        final freeSpaceMB = freeSpaceBytes / (1024 * 1024);
        hasEnoughSpace = freeSpaceMB >= 150;
      }
    } catch (e) {
      debugPrint("Tárhely lekérdezése sikertelen: \$e");
    }

    if (!context.mounted) return;

    final confettiController = ConfettiController(duration: const Duration(seconds: 3));
    String statusText = isDownloading.value ? "Letöltés..." : "Frissítés most";

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
                  const Divider(height: 15),
                  Text("Szükséges hely: ~${apkSizeMB.toStringAsFixed(1)} MB", style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  const Divider(height: 15),
                  const Text("Újdonságok:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).primaryColor.withValues(alpha: 0.12),
                          Theme.of(context).primaryColor.withValues(alpha: 0.04),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Theme.of(context).primaryColor.withValues(alpha: 0.25),
                        width: 1.2,
                      ),
                    ),
                    padding: const EdgeInsets.all(14),
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Text(
                        notes,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                  if (isDownloading.value) ...[
                    ValueListenableBuilder<double>(
                      valueListenable: downloadProgress,
                      builder: (context, progress, child) {
                        return Column(
                          children: [
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              height: 40,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned(
                                    top: 28,
                                    left: 0,
                                    right: 0,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: LinearProgressIndicator(
                                        value: progress,
                                        minHeight: 10,
                                        backgroundColor: Colors.grey[800],
                                        color: Colors.blue,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: AnimatedAlign(
                                      duration: const Duration(milliseconds: 200),
                                      alignment: Alignment(-1.0 + (progress * 2), 0),
                                      child: const Icon(Icons.rocket_launch, color: Colors.blue, size: 28),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 5),
                            Center(child: Text(
                              "${(progress * 100).toInt()}%",
                              style: const TextStyle(fontSize: 10, color: Colors.blue),
                            )),
                            const SizedBox(height: 10),
                            TextButton.icon(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.arrow_downward_rounded, size: 16),
                              label: const Text("Háttérbe küldés", style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        );
                      }
                    ),
                  ],
                ],
              ),
              actions: [
                if (!isDownloading.value)
                  TextButton(
                    onPressed: () {
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
                  onPressed: () async {
                    if (isDownloading.value) return; // Ha már tölt, nem csinálunk semmit

                    if (apkUrl != null) {
                      // 1. Tárhely ellenőrzés (a már lekérdezett adat alapján)
                      if (!hasEnoughSpace) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Nincs elég hely a telepítéshez! Szükséges: ~150 MB.")),
                          );
                        }
                        return;
                      }

                      // 2. Wi-Fi ellenőrzés (natív Kotlin kód hívása)
                      try {
                        final isWifi = await _platform.invokeMethod<bool>('isWifiConnected');
                        if (!context.mounted) return;
                        if (isWifi == false) {
                          bool? proceed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: Theme.of(ctx).colorScheme.surface,
                              title: const Text("Mobilnet figyelmeztetés"),
                              content: Text("Jelenleg mobilneten vagy. Egy ~${apkSizeMB.toStringAsFixed(1)} MB-os fájl letöltése következik. Biztosan folytatod?"),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Mégse")),
                                ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Folytatás")),
                              ],
                            )
                          );
                          if (proceed != true) return;
                        }
                      } catch (e) {
                        debugPrint("Wi-Fi ellenőrzés sikertelen: \$e");
                      }

                      if (isDownloadReady.value) {
                        installDownloadedApk();
                        Navigator.pop(context);
                        return;
                      }

                      // Alkalmazáson belüli letöltés + telepítés
                      setState(() {
                        isDownloading.value = true;
                        statusText = "Letöltés...";
                      });
                      final success = await _downloadAndInstall(apkUrl, context);
                      
                      // Ha az ablakot már bezárták (pl. háttérbe küldték), akkor itt megállunk
                      if (!context.mounted) return;

                      if (success) {
                        confettiController.play();
                        await Future.delayed(const Duration(milliseconds: 800));
                        installDownloadedApk();
                      }
                      
                      // Azonnal bezárjuk az ablakot, hogy ne akadjon meg
                      // amikor az Android átirányít a Beállításokba
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    } else {
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
    ).then((_) {
      // Várunk 300ms-ot, hogy az ablak bezárási animációja biztosan befejeződjön,
      // így a ConfettiWidget nem fog hibára futni a törölt controller miatt.
      Future.delayed(const Duration(milliseconds: 300), () {
        confettiController.dispose();
      });
    });
  }

  static Future<bool> _downloadAndInstall(String url, BuildContext context) async {
    isDownloading.value = true;
    isDownloadReady.value = false;
    downloadProgress.value = 0;

    try {
      final dio = Dio();
      final tempDir = await getTemporaryDirectory();
      final savePath = "${tempDir.path}/radiont_update.apk";

      debugPrint("APK letöltés indítása: $url");
      int lastUpdate = 0;
      await dio.download(
        url,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final now = DateTime.now().millisecondsSinceEpoch;
            // Frissítjük az UI-t, ha eltelt 100ms vagy befejeződött, hogy ne akadjon meg a UI szál
            if (now - lastUpdate > 100 || received == total) {
              downloadProgress.value = received / total;
              lastUpdate = now;
            }
          }
        },
      );

      final file = File(savePath);
      if (!await file.exists()) {
        isDownloading.value = false;
        return false;
      }

      final fileSize = await file.length();
      if (fileSize < 1000000) {
        isDownloading.value = false;
        return false;
      }

      downloadedFilePath = savePath;
      isDownloading.value = false;
      isDownloadReady.value = true;

      // Ha még nyitva van az ablak (nem háttérben fut), akkor indíthatjuk a telepítést
      // De biztonságosabb ha a felhasználó kattint rá a kész gombra.
      return true;
    } catch (e) {
      isDownloading.value = false;
      debugPrint("Letöltési hiba: $e");
      return false;
    }
  }

  static Future<void> installDownloadedApk() async {
    if (downloadedFilePath != null) {
      try {
        await _platform.invokeMethod('installApk', {'filePath': downloadedFilePath});
      } catch (e) {
        debugPrint("Telepítési hiba: $e");
      }
    }
  }
}

