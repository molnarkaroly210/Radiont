// lib/screens/download_webview_screen.dart
//
// Zene letöltő WebView – https://v2.y2mate.nu/
// Fájlletöltés: WebView cookie-kkal + közvetlen fájlírás a Music mappába

import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../providers/music_provider.dart';

class DownloadWebViewScreen extends StatefulWidget {
  final String? sharedUrl;
  final List<String>? playlistUrls;
  const DownloadWebViewScreen({super.key, this.sharedUrl, this.playlistUrls});

  @override
  State<DownloadWebViewScreen> createState() => _DownloadWebViewScreenState();
}

class _DownloadWebViewScreenState extends State<DownloadWebViewScreen> {
  double _progress = 0;
  bool _isLoading = true;
  String _pageTitle = 'Zene letöltése';
  InAppWebViewController? _webViewController;
  int _playlistIndex = 0;
  String? _currentUrl;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.sharedUrl;
  }

  /// Cookie-k lekérése a WebView-ból a letöltési URL domainhez
  Future<String> _getCookiesForUrl(String url) async {
    try {
      final cookieManager = CookieManager.instance();
      final cookies = await cookieManager.getCookies(url: WebUri(url));
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return '';
    }
  }

  /// Fájl letöltése a WebView-ból – cookie-kkal és közvetlen fájlírással
  Future<void> _downloadFile(BuildContext context, DownloadStartRequest request) async {
    final url = request.url.toString();
    final fileName = request.suggestedFilename ?? 'letoltes.mp3';
    final theme = Theme.of(context);

    // Cookie-k lekérése a WebView-ból
    final cookies = await _getCookiesForUrl(url);

    // Képernyő bekapcsolva tartása letöltés alatt
    WakelockPlus.enable();

    bool cancelled = false;
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) {
        double dlProgress = 0;
        String status = "Kapcsolódás...";
        bool started = false;

        final currentIdx = (_playlistIndex + 1);
        final totalCount = widget.playlistUrls?.length ?? 1;

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            if (!started) {
              started = true;
              _performDownload(
                url: url,
                cookies: cookies,
                fileName: fileName,
                onProgress: (p, s) {
                  if (!cancelled) setDialogState(() { dlProgress = p; status = s; });
                },
                onDone: (filePath) async {
                  if (cancelled) return;

                  setDialogState(() { dlProgress = 1.0; status = "Mentve!"; });

                  // MediaStore szkennelés
                  try { await OnAudioQuery().scanMedia(filePath); } catch (_) {}
                  try { await OnAudioQuery().scanMedia('/storage/emulated/0/'); } catch (_) {}

                  // Zenelista frissítése
                  if (context.mounted) {
                    context.read<MusicProvider>().fetchSongs();
                  }

                  // Kis várakozás, hogy a felhasználó lássa a "Mentve!" szöveget
                  await Future.delayed(const Duration(milliseconds: 800));

                  WakelockPlus.disable();

                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.white),
                            const SizedBox(width: 10),
                            Expanded(child: Text("Mentve: $fileName")),
                          ],
                        ),
                        backgroundColor: Colors.green.shade700,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        duration: const Duration(seconds: 4),
                      ),
                    );

                    // Következő elem a listából (ha van)
                    if (widget.playlistUrls != null && _playlistIndex < widget.playlistUrls!.length - 1) {
                      _playlistIndex++;
                      setState(() {
                        _currentUrl = widget.playlistUrls![_playlistIndex];
                      });
                      _webViewController?.loadUrl(
                        urlRequest: URLRequest(url: WebUri('https://v2.y2mate.nu/')),
                      );
                    } else {
                      // Ha végeztünk a listával, töröljük az aktuális URL-t, hogy ne induljon újra
                      setState(() {
                        _currentUrl = null;
                      });

                      if (widget.playlistUrls != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Row(
                              children: [
                                Icon(Icons.check_circle, color: Colors.white),
                                SizedBox(width: 10),
                                Text("A lejátszási lista összes eleme letöltve!"),
                              ],
                            ),
                            backgroundColor: Colors.green.shade800,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        );
                      }

                      // WebView újratöltése alapállapotba
                      _webViewController?.loadUrl(
                        urlRequest: URLRequest(url: WebUri('https://v2.y2mate.nu/')),
                      );
                    }
                  }
                },
                onError: (error) {
                  WakelockPlus.disable();
                  if (cancelled) return;
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Colors.white),
                            const SizedBox(width: 10),
                            Expanded(child: Text("Hiba: $error")),
                          ],
                        ),
                        backgroundColor: Colors.red.shade700,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        duration: const Duration(seconds: 5),
                      ),
                    );
                  }
                },
              );
            }

            // Dialog UI
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF1C1C2E)
                        : Colors.white,
                    border: Border.all(
                      color: theme.primaryColor.withValues(alpha: 0.3),
                      width: 1.5,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          dlProgress >= 1.0 ? Icons.check_circle_rounded : Icons.downloading_rounded,
                          color: dlProgress >= 1.0 ? Colors.green : theme.primaryColor,
                          size: 40,
                        ),
                        const SizedBox(height: 10),
                        if (widget.playlistUrls != null)
                          Text(
                            "Letöltés: $currentIdx / $totalCount",
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        const SizedBox(height: 15),
                        Text(
                          fileName,
                          style: theme.textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: dlProgress > 0 ? dlProgress : null,
                            backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.2),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              dlProgress >= 1.0 ? Colors.green : theme.primaryColor,
                            ),
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 15),
                        Text(status, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
                        const SizedBox(height: 15),
                        if (dlProgress < 1.0)
                          TextButton(
                            onPressed: () { 
                              cancelled = true; 
                              WakelockPlus.disable();
                              Navigator.of(dialogContext).pop(); 
                            },
                            child: Text("Mégse", style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// HTTP letöltés cookie-kkal + fájl mentés a Music mappába
  Future<void> _performDownload({
    required String url,
    required String cookies,
    required String fileName,
    required void Function(double progress, String status) onProgress,
    required void Function(String filePath) onDone,
    required void Function(String error) onError,
  }) async {
    try {
      onProgress(0, "Kapcsolódás...");

      // HttpClient használata (cookie-k támogatásával)
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 30);

      final request = await httpClient.getUrl(Uri.parse(url));

      // Cookie-k és User-Agent beállítása (a WebView-ból)
      if (cookies.isNotEmpty) {
        request.headers.set('Cookie', cookies);
      }
      request.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36');
      request.headers.set('Referer', 'https://v2.y2mate.nu/');

      final response = await request.close();

      // Átirányítások követése
      if (response.statusCode == 301 || response.statusCode == 302) {
        final redirectUrl = response.headers.value('location');
        httpClient.close();
        if (redirectUrl != null) {
          return _performDownload(
            url: redirectUrl,
            cookies: cookies,
            fileName: fileName,
            onProgress: onProgress,
            onDone: onDone,
            onError: onError,
          );
        }
        onError("Átirányítási hiba");
        return;
      }

      if (response.statusCode != 200) {
        httpClient.close();
        onError("HTTP hiba: ${response.statusCode}");
        return;
      }

      // Mentési hely meghatározása
      final saveDir = await _getDownloadDirectory();
      final filePath = '$saveDir/$fileName';
      final file = File(filePath);

      // Letöltés streameléssel + fájlba írás
      final totalBytes = response.contentLength;
      int downloadedBytes = 0;
      final sink = file.openWrite();

      onProgress(0, "Letöltés: 0%");

      await for (final chunk in response) {
        sink.add(chunk);
        downloadedBytes += chunk.length;

        double progress = (totalBytes > 0) ? downloadedBytes / totalBytes : 0;
        String status = totalBytes > 0
            ? "Letöltés: ${(progress * 100).toStringAsFixed(0)}% (${_formatBytes(downloadedBytes)}/${_formatBytes(totalBytes)})"
            : "Letöltés: ${_formatBytes(downloadedBytes)}";
        onProgress(progress, status);
      }

      await sink.flush();
      await sink.close();
      httpClient.close();

      // Ellenőrzés: létrejött-e a fájl és van-e benne adat
      if (!file.existsSync() || file.lengthSync() < 100) {
        onError("A fájl üres vagy nem jött létre.");
        return;
      }

      onDone(filePath);
    } catch (e) {
      onError(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Letöltési mappa meghatározása (Music > Radiont)
  Future<String> _getDownloadDirectory() async {
    // Először próbáljuk a Music mappát
    final musicDir = Directory('/storage/emulated/0/Music/Radiont');
    if (!musicDir.existsSync()) {
      musicDir.createSync(recursive: true);
    }
    if (musicDir.existsSync()) {
      return musicDir.path;
    }

    // Fallback: Download mappa
    final downloadDir = Directory('/storage/emulated/0/Download/Radiont');
    if (!downloadDir.existsSync()) {
      downloadDir.createSync(recursive: true);
    }
    if (downloadDir.existsSync()) {
      return downloadDir.path;
    }

    // Utolsó fallback: app documents mappa
    final appDir = await getApplicationDocumentsDirectory();
    return appDir.path;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0A0A1A) : Colors.white,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded, color: theme.colorScheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              _pageTitle,
              style: theme.textTheme.titleMedium?.copyWith(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_rounded, size: 12, color: theme.primaryColor),
                const SizedBox(width: 4),
                Text(
                  'Privát DNS aktív',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 11,
                    color: theme.primaryColor,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: theme.colorScheme.onSurface),
            onPressed: () => _webViewController?.reload(),
          ),
        ],
        bottom: _isLoading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(theme.primaryColor),
                  minHeight: 3,
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('https://v2.y2mate.nu/'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            databaseEnabled: true,
            cacheEnabled: true,
            supportZoom: true,
            useWideViewPort: true,
            loadWithOverviewMode: true,
            useOnDownloadStart: true,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            userAgent: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          ),
          onWebViewCreated: (controller) {
            _webViewController = controller;
          },
          onLoadStart: (controller, url) {
            setState(() { _isLoading = true; _progress = 0; });
          },
          onProgressChanged: (controller, progress) {
            setState(() { _progress = progress / 100; });
          },
          onLoadStop: (controller, url) async {
            final title = await controller.getTitle();
            setState(() {
              _isLoading = false;
              if (title != null && title.isNotEmpty) _pageTitle = title;
            });

            // Ha van megosztott URL, beillesztjük a keresőmezőbe
            if (_currentUrl != null && url != null && url.toString().contains('y2mate.nu')) {
              await controller.evaluateJavascript(source: """
                (function() {
                  // 1. URL beillesztése és konvertálás indítása
                  var input = document.getElementById('video') || document.querySelector('input[type="text"]');
                  if (input && input.value === '') {
                    input.value = '$_currentUrl';
                    input.dispatchEvent(new Event('input', { bubbles: true }));
                    
                    var btn = document.querySelector('button[type="submit"]') || 
                              document.querySelector('input[type="submit"]') ||
                              document.querySelector('.btn-convert');
                    if (btn) {
                      setTimeout(() => btn.click(), 1000);
                    }
                  }

                  // 2. Automatikus kattintás a letöltés gombra, ha megjelent
                  var checkCount = 0;
                  var checkDownloadBtn = setInterval(function() {
                    checkCount++;
                    
                    // Minden gombot és linket megvizsgálunk, hátha valamelyik a letöltés
                    var allElements = document.querySelectorAll('a, button, div[role="button"]');
                    var found = false;
                    
                    for (var i = 0; i < allElements.length; i++) {
                      var el = allElements[i];
                      var text = el.innerText.toLowerCase();
                      
                      // Csak ha látható és "Download" vagy "Letöltés" szerepel benne
                      if (el.offsetParent !== null && (text.includes('download') || text.includes('letöltés'))) {
                        el.click();
                        found = true;
                        break;
                      }
                    }
                    
                    if (found) {
                      clearInterval(checkDownloadBtn);
                    }
                    
                    // 60 másodperc után feladjuk
                    if (checkCount > 30) clearInterval(checkDownloadBtn);
                  }, 2000);
                })();
              """);
            }
          },
          onReceivedError: (controller, request, error) {
            setState(() => _isLoading = false);
          },
          // === Fájl letöltés kezelése ===
          onDownloadStartRequest: (controller, request) async {
            if (mounted) {
              _downloadFile(context, request);
            }
          },
        ),
      ),
    );
  }
}
