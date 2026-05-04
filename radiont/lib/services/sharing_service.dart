import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../screens/download_webview_screen.dart';

class SharingService {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static StreamSubscription? _intentDataStreamSubscription;

  static void init() {
    // Kezeli a megosztott adatokat, ha az alkalmazás már fut a háttérben
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      if (value.isNotEmpty) {
        _handleSharedMedia(value);
      }
    }, onError: (err) {
      debugPrint("SharingService error: $err");
    });

    // Kezeli a megosztott adatokat, ha az alkalmazás most indul el
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty) {
        _handleSharedMedia(value);
      }
      // Fontos: Miután feldolgoztuk a kezdeti médiát, töröljük az intentet, 
      // hogy ne hívódjon meg újra pl. képernyő forgatásnál.
      ReceiveSharingIntent.instance.reset();
    });
  }

  static void _handleSharedMedia(List<SharedMediaFile> media) {
    // Megkeressük az első szöveges elemet (linket)
    for (var item in media) {
      if (item.type == SharedMediaType.text || item.type == SharedMediaType.url) {
        _processText(item.path);
        return;
      }
    }
  }

  static void _processText(String text) {
    // Megpróbáljuk kinyerni az URL-t a szövegből (pl. YouTube megosztásnál van kísérőszöveg is)
    final urlRegex = RegExp(r'(https?://[^\s]+)');
    final match = urlRegex.firstMatch(text);
    
    if (match != null) {
      String url = match.group(0)!;
      
      if (_isYouTubeUrl(url)) {
        _navigateToDownloader(url);
      } else {
        _showError("Érvénytelen link");
      }
    } else {
      _showError("Nem található link a megosztásban");
    }
  }

  static bool _isYouTubeUrl(String url) {
    final ytRegex = RegExp(
      r'^(https?://)?(www\.)?(youtube\.com|youtu\.be|music\.youtube\.com)/.+$',
      caseSensitive: false,
    );
    return ytRegex.hasMatch(url);
  }

  static void _navigateToDownloader(String url) {
    // Rövid várakozás, hogy az app biztosan betöltődjön
    Future.delayed(const Duration(milliseconds: 500), () {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => DownloadWebViewScreen(sharedUrl: url),
        ),
      );
    });
  }

  static void _showError(String message) {
    final context = navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: Colors.red.shade800,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  static void dispose() {
    _intentDataStreamSubscription?.cancel();
  }
}
