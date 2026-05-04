import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
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
      
      if (_isYouTubePlaylistUrl(url)) {
        _handlePlaylistUrl(url);
      } else if (_isYouTubeUrl(url)) {
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

  static bool _isYouTubePlaylistUrl(String url) {
    return url.contains('list=') || url.contains('/playlist?');
  }

  static void _handlePlaylistUrl(String url) async {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    // Mutatunk egy betöltőt, amíg kinyerjük a linkeket
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final yt = YoutubeExplode();
    try {
      final playlistId = PlaylistId.parsePlaylistId(url);
      if (playlistId != null) {
        final videos = await yt.playlists.getVideos(playlistId).toList();
        final urls = videos.map((v) => 'https://www.youtube.com/watch?v=${v.id.value}').toList();
        
        if (context.mounted) Navigator.pop(context); // Betöltő bezárása
        
        if (urls.isNotEmpty) {
          _navigateToDownloader(urls.first, playlistUrls: urls);
        } else {
          _showError("A lejátszási lista üres.");
        }
      }
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      _showError("Hiba a lista feldolgozásakor: $e");
    } finally {
      yt.close();
    }
  }

  static void _navigateToDownloader(String url, {List<String>? playlistUrls}) {
    // Rövid várakozás, hogy az app biztosan betöltődjön
    Future.delayed(const Duration(milliseconds: 500), () {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => DownloadWebViewScreen(
            sharedUrl: url,
            playlistUrls: playlistUrls,
          ),
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
