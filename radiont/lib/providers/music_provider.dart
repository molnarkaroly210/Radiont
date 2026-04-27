import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_saver/file_saver.dart';

class MusicProvider extends ChangeNotifier {
  final SharedPreferences prefs;
  final AudioPlayer audioPlayer = AudioPlayer();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  List<SongModel> _songs = [];
  bool _isLoading = true;
  bool _hasPermission = false;
  int _currentIndex = 0;
  bool _isShuffleModeEnabled = false;
  LoopMode _loopMode = LoopMode.off;

  // Letöltési állapot (a MusicScreen overlay-hez, ha kell)
  bool _isDownloading = false;
  double _downloadProgress = 0;
  String _downloadStatus = "";

  MusicProvider(this.prefs) {
    _init();
  }

  bool get isLoading => _isLoading;
  bool get hasPermission => _hasPermission;
  List<SongModel> get songs => _songs;
  int get currentIndex => _currentIndex;
  SongModel? get currentSong => _songs.isNotEmpty && _currentIndex < _songs.length ? _songs[_currentIndex] : null;
  bool get isShuffleModeEnabled => _isShuffleModeEnabled;
  LoopMode get loopMode => _loopMode;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get downloadStatus => _downloadStatus;

  Future<void> _init() async {
    audioPlayer.playerStateStream.listen((state) {
      notifyListeners();
    });

    audioPlayer.currentIndexStream.listen((index) {
      if (index != null && index != _currentIndex) {
        _currentIndex = index;
        notifyListeners();
      }
    });

    audioPlayer.loopModeStream.listen((mode) {
      _loopMode = mode;
      notifyListeners();
    });

    audioPlayer.shuffleModeEnabledStream.listen((enabled) {
      _isShuffleModeEnabled = enabled;
      notifyListeners();
    });

    await _checkPermissionsAndFetch();
  }

  Future<void> _checkPermissionsAndFetch() async {
    _isLoading = true;
    notifyListeners();

    _hasPermission = await _audioQuery.checkAndRequest(
      retryRequest: true,
    );

    if (_hasPermission) {
      await fetchSongs();
    } else {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> requestPermission() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.storage,
        Permission.audio,
        Permission.photos,
        Permission.videos,
      ].request();
      
      _hasPermission = (statuses[Permission.audio]?.isGranted ?? false) || 
                       (statuses[Permission.storage]?.isGranted ?? false) ||
                       (statuses[Permission.photos]?.isGranted ?? false) ||
                       (statuses[Permission.videos]?.isGranted ?? false);

      if (!_hasPermission) {
        bool permanentlyDenied = (statuses[Permission.audio]?.isPermanentlyDenied ?? false) || 
                                 (statuses[Permission.storage]?.isPermanentlyDenied ?? false);
        if (permanentlyDenied) {
          await openAppSettings();
        }
      }
    } else {
      _hasPermission = true; 
    }
    
    if (_hasPermission) {
      await fetchSongs();
    }
    notifyListeners();
  }

  Future<void> fetchSongs() async {
    _isLoading = true;
    notifyListeners();

    List<SongModel> allSongs = await _audioQuery.querySongs(
      sortType: null,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    _songs = allSongs;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> playSong(int index) async {
    if (_songs.isEmpty) return;

    _currentIndex = index;
    final audioSources = _songs.map((song) {
      return AudioSource.uri(
        Uri.parse(song.uri!),
        tag: MediaItem(
          id: song.id.toString(),
          album: song.album ?? "Ismeretlen Album",
          title: song.title,
          artist: song.artist ?? "Ismeretlen Előadó",
          artUri: null,
        ),
      );
    }).toList();

    try {
      await audioPlayer.setAudioSource(
        ConcatenatingAudioSource(children: audioSources),
        initialIndex: index,
        initialPosition: Duration.zero,
      );
      audioPlayer.play();
    } catch (e) {
      if (kDebugMode) print("Hiba a lejátszás közben: $e");
    }
  }

  void togglePlayPause() {
    if (audioPlayer.playing) {
      audioPlayer.pause();
    } else {
      audioPlayer.play();
    }
  }

  void nextSong() {
    if (audioPlayer.hasNext) {
      audioPlayer.seekToNext();
    } else {
      if (!_isShuffleModeEnabled) {
        audioPlayer.seek(Duration.zero, index: 0);
        audioPlayer.play();
      }
    }
  }

  void previousSong() {
    if (audioPlayer.hasPrevious) {
      audioPlayer.seekToPrevious();
    } else {
      audioPlayer.seek(Duration.zero);
    }
  }

  void seek(Duration position) {
    audioPlayer.seek(position);
  }

  Future<void> toggleShuffle() async {
    final enable = !audioPlayer.shuffleModeEnabled;
    if (enable) {
      await audioPlayer.shuffle();
    }
    await audioPlayer.setShuffleModeEnabled(enable);
  }

  Future<void> toggleRepeat() async {
    LoopMode nextMode;
    switch (_loopMode) {
      case LoopMode.off:
        nextMode = LoopMode.all;
        break;
      case LoopMode.all:
        nextMode = LoopMode.one;
        break;
      case LoopMode.one:
        nextMode = LoopMode.off;
        break;
    }
    await audioPlayer.setLoopMode(nextMode);
  }

  // ============================================================
  // YouTube Zene Letöltés - stream.listen() + callback alapú
  // ============================================================
  // Működése:
  // 1. YoutubeExplode: videó metaadatok + audio manifest lekérése
  // 2. stream.listen(): byte-ok összegyűjtése memóriába, valós idejű progresszió
  // 3. onDone: FileSaver mentés + MediaStore szkennelés
  // 4. A hívó (UI) a callback-eken keresztül kapja a frissítéseket
  // ============================================================

  Future<void> downloadYoutubeVideo(
    String url, {
    void Function(double progress, String status)? onProgress,
    void Function(String fileName)? onDone,
    void Function(String error)? onError,
  }) async {
    if (url.isEmpty) return;

    // 1. Engedélyek ellenőrzése
    if (!_hasPermission) {
      await requestPermission();
      if (!_hasPermission) {
        onError?.call("Nincs tárhely engedély. Engedélyezd a beállításokban!");
        return;
      }
    }

    _isDownloading = true;
    notifyListeners();

    // 2. Video ID kinyerése
    String? videoId;
    try {
      videoId = VideoId.parseVideoId(url);
    } catch (_) {}

    if (videoId == null) {
      _isDownloading = false;
      notifyListeners();
      onError?.call("Érvénytelen YouTube link.");
      return;
    }

    // 3. YouTube motor indítása
    var yt = YoutubeExplode();

    try {
      // Videó metaadatok lekérése
      onProgress?.call(0, "Adatok lekérése...");
      var video = await yt.videos.get(videoId).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception("Időtúllépés az adatok lekérésekor."),
      );

      // Audio manifest lekérése
      onProgress?.call(0, "Adatfolyam keresése...");
      var manifest = await yt.videos.streamsClient.getManifest(videoId).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception("Időtúllépés az adatfolyam keresésekor."),
      );

      // A legjobb minőségű audio-only stream kiválasztása
      var audioStreamInfo = manifest.audioOnly.withHighestBitrate();
      var audioStream = yt.videos.streamsClient.get(audioStreamInfo);

      // 4. Fájlnév tisztítása (Kritikus! Illegális karakterek eltávolítása)
      String safeTitle = video.title.replaceAll(RegExp(r'[\\/<>:"|?*]'), '_');
      safeTitle = safeTitle.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (safeTitle.isEmpty) safeTitle = 'youtube_audio_$videoId';

      // 5. Stream.listen() - valós idejű progresszióval
      int totalBytes = audioStreamInfo.size.totalBytes;
      int downloadedBytes = 0;
      final List<int> allBytes = [];
      final Completer<void> completer = Completer<void>();

      onProgress?.call(0, "Letöltés: 0%");

      audioStream.listen(
        // Minden egyes adatcsomag (chunk) érkezésekor
        (List<int> chunk) {
          allBytes.addAll(chunk);
          downloadedBytes += chunk.length;

          // Százalék kiszámítása és UI frissítés
          double progress = totalBytes > 0 ? downloadedBytes / totalBytes : 0;
          String status = "Letöltés: ${(progress * 100).toStringAsFixed(0)}%";

          // Provider állapot frissítése (a MusicScreen overlay-hez)
          _downloadProgress = progress;
          _downloadStatus = status;
          notifyListeners();

          // Callback a StatefulBuilder dialog-hoz (közvetlen UI frissítés!)
          onProgress?.call(progress, status);
        },

        // Amikor a stream befejeződött (minden byte megérkezett)
        onDone: () async {
          try {
            // Ellenőrzés: érkezett-e elegendő adat?
            if (allBytes.length < 1000) {
              throw Exception("Nem érkezett elegendő adat a szerverről.");
            }

            // FileSaver mentés (Android Scoped Storage kompatibilis!)
            onProgress?.call(1.0, "Mentés...");
            _downloadStatus = "Mentés...";
            notifyListeners();

            final Uint8List fileBytes = Uint8List.fromList(allBytes);
            await FileSaver.instance.saveFile(
              name: safeTitle,
              bytes: fileBytes,
              ext: 'm4a',
              mimeType: MimeType.aac,
            );

            // MediaStore frissítése, hogy megjelenjen a zenéknél
            try {
              await _audioQuery.scanMedia('/storage/emulated/0/');
            } catch (_) {}

            await fetchSongs();

            // Siker callback
            onDone?.call("$safeTitle.m4a");
            if (!completer.isCompleted) completer.complete();
          } catch (e) {
            onError?.call(e.toString().replaceAll('Exception: ', ''));
            if (!completer.isCompleted) completer.completeError(e);
          }
        },

        // Hiba esetén (pl. HTTP 403, hálózati hiba)
        onError: (error) {
          onError?.call(error.toString());
          if (!completer.isCompleted) completer.completeError(error);
        },

        cancelOnError: true,
      );

      // Megvárjuk, amíg a stream teljesen befejeződik
      await completer.future;

    } catch (e) {
      // Bármilyen egyéb hiba (timeout, parse error, stb.)
      onError?.call(e.toString().replaceAll('Exception: ', ''));
    } finally {
      // Erőforrások felszabadítása (KÖTELEZŐ!)
      yt.close();
      _isDownloading = false;
      _downloadProgress = 0;
      _downloadStatus = "";
      notifyListeners();
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    super.dispose();
  }
}
