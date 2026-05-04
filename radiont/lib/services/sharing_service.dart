import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:provider/provider.dart';
import '../screens/download_webview_screen.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../providers/music_provider.dart';

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
        final playlist = await yt.playlists.get(playlistId);
        final videos = await yt.playlists.getVideos(playlistId).toList();
        
        if (context.mounted) Navigator.pop(context); // Betöltő bezárása
        
        if (videos.isNotEmpty) {
          if (context.mounted) {
            final List<String>? selectedUrls = await showDialog<List<String>>(
              context: context,
              barrierDismissible: false,
              builder: (context) => PlaylistSelectionDialog(
                videos: videos,
                playlistTitle: playlist.title,
              ),
            );

            if (selectedUrls != null && selectedUrls.isNotEmpty) {
              _navigateToDownloader(selectedUrls.first, playlistUrls: selectedUrls);
            }
          }
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

  static void _navigateToDownloader(String url, {List<String>? playlistUrls}) async {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    // Ha egyedi link, megnézzük, megvan-e már
    if (playlistUrls == null) {
      final yt = YoutubeExplode();
      try {
        final video = await yt.videos.get(url);
        if (context.mounted && context.read<MusicProvider>().isDuplicate(video.title)) {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text("Már megvan"),
              content: Text("Úgy tűnik, hogy a(z) '${video.title}' már szerepel a könyvtáradban.\n\nSzeretnéd ennek ellenére letölteni?"),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Mégse")),
                ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Letöltés")),
              ],
            ),
          );
          if (confirm != true) {
            yt.close();
            return;
          }
        }
      } catch (_) {
        // Hiba esetén (pl. privát videó) engedjük tovább a WebView-ra, ott majd kiderül
      } finally {
        yt.close();
      }
    }

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
