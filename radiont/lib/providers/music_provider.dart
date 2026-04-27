import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_saver/file_saver.dart';
import '../models/album_model.dart';

// Rendezési módok
enum SortMode { title, artist, dateAdded, duration, playCount }

class MusicProvider extends ChangeNotifier {
  final SharedPreferences prefs;
  final AudioPlayer audioPlayer = AudioPlayer();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  // === Alapvető zenelista ===
  List<SongModel> _songs = [];
  bool _isLoading = true;
  bool _hasPermission = false;
  int _currentIndex = 0;
  int? _currentPlayingSongId; // A jelenleg lejátszott zene ID-ja
  bool _hasStartedPlaying = false;
  bool _isShuffleModeEnabled = false;
  LoopMode _loopMode = LoopMode.off;

  // === Albumok & Archiválás ===
  List<Album> _albums = [];
  Set<int> _archivedSongIds = {};
  String? _selectedAlbumId; // null = Összes, "uncategorized", "most_played", vagy album id

  // === Keresés & Rendezés ===
  String _searchQuery = '';
  SortMode _sortMode = SortMode.title;

  // === Lejátszási sor ===
  List<SongModel> _queue = [];

  // === Hallgatási statisztika ===
  Map<int, int> _playCounts = {};

  // === Alvásidőzítő ===
  Timer? _sleepTimer;
  Timer? _sleepTickTimer;
  Duration? _sleepTimerRemaining;

  // === Letöltési állapot ===
  bool _isDownloading = false;
  double _downloadProgress = 0;
  String _downloadStatus = "";

  MusicProvider(this.prefs) {
    _init();
  }

  // ================================================================
  // GETTEREK
  // ================================================================

  bool get isLoading => _isLoading;
  bool get hasPermission => _hasPermission;
  List<SongModel> get songs => _songs;
  int get currentIndex => _hasStartedPlaying ? _currentIndex : -1;
  int? get currentPlayingSongId => _hasStartedPlaying ? _currentPlayingSongId : null;
  SongModel? get currentSong {
    if (!_hasStartedPlaying || _currentPlayingSongId == null) return null;
    return _songs.where((s) => s.id == _currentPlayingSongId).firstOrNull;
  }
  bool get hasStartedPlaying => _hasStartedPlaying;
  bool get isShuffleModeEnabled => _isShuffleModeEnabled;
  LoopMode get loopMode => _loopMode;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get downloadStatus => _downloadStatus;

  // Albumok & Archiválás
  List<Album> get albums => _albums;
  String? get selectedAlbumId => _selectedAlbumId;
  Set<int> get archivedSongIds => _archivedSongIds;

  // Keresés & Rendezés
  String get searchQuery => _searchQuery;
  SortMode get sortMode => _sortMode;

  // Alvásidőzítő
  Duration? get sleepTimerRemaining => _sleepTimerRemaining;
  bool get isSleepTimerActive => _sleepTimer != null;

  // Lejátszási sor
  List<SongModel> get queue => _queue;

  // Hallgatási statisztika
  Map<int, int> get playCounts => _playCounts;
  int getPlayCount(int songId) => _playCounts[songId] ?? 0;

  /// Szűrt + rendezett zenelista (ez jelenik meg a UI-ban)
  List<SongModel> get displayedSongs {
    List<SongModel> result = _songs.where((s) => !_archivedSongIds.contains(s.id)).toList();

    // Album szűrés
    if (_selectedAlbumId == 'uncategorized') {
      final allAlbumSongIds = _albums.expand((a) => a.songIds).toSet();
      result = result.where((s) => !allAlbumSongIds.contains(s.id)).toList();
    } else if (_selectedAlbumId == 'most_played') {
      // Top 25 leggyakrabban hallgatott
      result.sort((a, b) => (getPlayCount(b.id)).compareTo(getPlayCount(a.id)));
      result = result.where((s) => getPlayCount(s.id) > 0).take(25).toList();
    } else if (_selectedAlbumId != null) {
      final album = _albums.where((a) => a.id == _selectedAlbumId).firstOrNull;
      if (album != null) {
        // Album sorrendjét megtartjuk (drag & drop)
        final songMap = {for (var s in result) s.id: s};
        result = album.songIds
            .where((id) => songMap.containsKey(id))
            .map((id) => songMap[id]!)
            .toList();
        // Ha album van kiválasztva, ne rendezzük felül a sorrendet
        return _applySearch(result);
      }
    }

    // Rendezés (nem album módban)
    result = _applySorting(result);

    // Keresés
    result = _applySearch(result);

    return result;
  }

  /// Archivált zenék listája (a settings-hez)
  List<SongModel> get archivedSongs {
    return _songs.where((s) => _archivedSongIds.contains(s.id)).toList();
  }

  /// Top 25 leggyakrabban hallgatott
  List<SongModel> get mostPlayedSongs {
    final nonArchived = _songs.where((s) => !_archivedSongIds.contains(s.id)).toList();
    nonArchived.sort((a, b) => getPlayCount(b.id).compareTo(getPlayCount(a.id)));
    return nonArchived.where((s) => getPlayCount(s.id) > 0).take(25).toList();
  }

  // ================================================================
  // INICIALIZÁLÁS
  // ================================================================

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

    _loadPersistedData();
    await _checkPermissionsAndFetch();
  }

  /// Perzisztált adatok betöltése SharedPreferences-ből
  void _loadPersistedData() {
    // Albumok
    final albumsJson = prefs.getString('music_albums');
    if (albumsJson != null && albumsJson.isNotEmpty) {
      try {
        _albums = Album.listFromJson(albumsJson);
      } catch (_) {
        _albums = [];
      }
    }

    // Archivált zenék
    final archivedJson = prefs.getStringList('music_archived');
    if (archivedJson != null) {
      _archivedSongIds = archivedJson.map((e) => int.tryParse(e) ?? 0).where((e) => e > 0).toSet();
    }

    // Hallgatási számlálók
    final countsJson = prefs.getString('music_play_counts');
    if (countsJson != null && countsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(countsJson) as Map<String, dynamic>;
        _playCounts = decoded.map((k, v) => MapEntry(int.parse(k), v as int));
      } catch (_) {
        _playCounts = {};
      }
    }

    // Rendezési mód
    final sortIndex = prefs.getInt('music_sort_mode') ?? 0;
    if (sortIndex < SortMode.values.length) {
      _sortMode = SortMode.values[sortIndex];
    }
  }

  Future<void> _saveAlbums() async {
    await prefs.setString('music_albums', Album.listToJson(_albums));
  }

  Future<void> _saveArchive() async {
    await prefs.setStringList('music_archived', _archivedSongIds.map((e) => e.toString()).toList());
  }

  Future<void> _savePlayCounts() async {
    final encoded = jsonEncode(_playCounts.map((k, v) => MapEntry(k.toString(), v)));
    await prefs.setString('music_play_counts', encoded);
  }

  // ================================================================
  // ENGEDÉLYEK & ZENÉK BETÖLTÉSE
  // ================================================================

  bool _isRequestingPermission = false;

  Future<void> _checkPermissionsAndFetch() async {
    if (_isRequestingPermission) return;
    _isRequestingPermission = true;
    _isLoading = true;
    notifyListeners();

    try {
      final status = await Permission.audio.status;
      if (status.isGranted) {
        _hasPermission = true;
        await fetchSongs();
      } else {
        final storageStatus = await Permission.storage.status;
        if (storageStatus.isGranted) {
          _hasPermission = true;
          await fetchSongs();
        } else {
          // Csak ellenőrzés, nem kérés – a kérést a requestPermission végzi
          _hasPermission = false;
          _isLoading = false;
          notifyListeners();
        }
      }
    } finally {
      _isRequestingPermission = false;
    }
  }

  Future<void> requestPermission() async {
    if (_isRequestingPermission) return;
    _isRequestingPermission = true;
    notifyListeners();

    try {
      var status = await Permission.audio.request();
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      _hasPermission = status.isGranted;
      if (_hasPermission) {
        await fetchSongs();
      } else {
        notifyListeners();
      }
    } catch (_) {
      // Permission already running – ignoráljuk
    } finally {
      _isRequestingPermission = false;
    }
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

  // ================================================================
  // KERESÉS & RENDEZÉS
  // ================================================================

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setSortMode(SortMode mode) {
    _sortMode = mode;
    prefs.setInt('music_sort_mode', mode.index);
    notifyListeners();
  }

  List<SongModel> _applySearch(List<SongModel> songs) {
    if (_searchQuery.isEmpty) return songs;
    final q = _searchQuery.toLowerCase();
    return songs.where((s) {
      return s.title.toLowerCase().contains(q) ||
          (s.artist?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  List<SongModel> _applySorting(List<SongModel> songs) {
    switch (_sortMode) {
      case SortMode.title:
        songs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case SortMode.artist:
        songs.sort((a, b) => (a.artist ?? '').toLowerCase().compareTo((b.artist ?? '').toLowerCase()));
        break;
      case SortMode.dateAdded:
        songs.sort((a, b) => (b.dateAdded ?? 0).compareTo(a.dateAdded ?? 0));
        break;
      case SortMode.duration:
        songs.sort((a, b) => (b.duration ?? 0).compareTo(a.duration ?? 0));
        break;
      case SortMode.playCount:
        songs.sort((a, b) => getPlayCount(b.id).compareTo(getPlayCount(a.id)));
        break;
    }
    return songs;
  }

  // ================================================================
  // ZENEKEZELÉS – TÖRLÉS & ARCHIVÁLÁS
  // ================================================================

  /// Zene törlése a telefonról
  Future<bool> deleteSong(SongModel song) async {
    try {
      final uri = song.uri;
      if (uri != null) {
        final file = File(uri);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Eltávolítás az albumokból
      for (final album in _albums) {
        album.songIds.remove(song.id);
      }
      await _saveAlbums();

      // Eltávolítás az archívumból
      _archivedSongIds.remove(song.id);
      await _saveArchive();

      // Play count eltávolítása
      _playCounts.remove(song.id);
      await _savePlayCounts();

      // Zenelista frissítése
      await fetchSongs();
      return true;
    } catch (e) {
      if (kDebugMode) print("Törlési hiba: $e");
      return false;
    }
  }

  /// Zene archiválása (elrejtése a listából, de a telefonon megmarad)
  void archiveSong(int songId) {
    _archivedSongIds.add(songId);
    _saveArchive();
    notifyListeners();
  }

  /// Zene visszaállítása az archívumból
  void unarchiveSong(int songId) {
    _archivedSongIds.remove(songId);
    _saveArchive();
    notifyListeners();
  }

  // ================================================================
  // ALBUMOK
  // ================================================================

  /// Új album létrehozása
  void createAlbum(String name, {double hue = 200}) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _albums.add(Album(id: id, name: name, hue: hue));
    _saveAlbums();
    notifyListeners();
  }

  /// Album törlése
  void deleteAlbum(String albumId) {
    _albums.removeWhere((a) => a.id == albumId);
    if (_selectedAlbumId == albumId) _selectedAlbumId = null;
    _saveAlbums();
    notifyListeners();
  }

  /// Album átnevezése
  void renameAlbum(String albumId, String newName) {
    final album = _albums.where((a) => a.id == albumId).firstOrNull;
    if (album != null) {
      album.name = newName;
      _saveAlbums();
      notifyListeners();
    }
  }

  /// Album szín módosítása
  void setAlbumColor(String albumId, double hue) {
    final album = _albums.where((a) => a.id == albumId).firstOrNull;
    if (album != null) {
      album.hue = hue;
      _saveAlbums();
      notifyListeners();
    }
  }

  /// Zene hozzáadása albumhoz
  void addSongToAlbum(String albumId, int songId) {
    final album = _albums.where((a) => a.id == albumId).firstOrNull;
    if (album != null && !album.songIds.contains(songId)) {
      album.songIds.add(songId);
      _saveAlbums();
      notifyListeners();
    }
  }

  /// Zene eltávolítása albumból
  void removeSongFromAlbum(String albumId, int songId) {
    final album = _albums.where((a) => a.id == albumId).firstOrNull;
    if (album != null) {
      album.songIds.remove(songId);
      _saveAlbums();
      notifyListeners();
    }
  }

  /// Drag & drop rendezés albumon belül
  void reorderSongInAlbum(String albumId, int oldIndex, int newIndex) {
    final album = _albums.where((a) => a.id == albumId).firstOrNull;
    if (album != null) {
      if (newIndex > oldIndex) newIndex--;
      final songId = album.songIds.removeAt(oldIndex);
      album.songIds.insert(newIndex, songId);
      _saveAlbums();
      notifyListeners();
    }
  }

  /// Album kiválasztása szűrőnek
  void selectAlbum(String? albumId) {
    _selectedAlbumId = albumId;
    notifyListeners();
  }

  /// Ellenőrzi, hogy egy zene benne van-e az adott albumban
  bool isSongInAlbum(String albumId, int songId) {
    final album = _albums.where((a) => a.id == albumId).firstOrNull;
    return album?.songIds.contains(songId) ?? false;
  }

  // ================================================================
  // HALLGATÁSI STATISZTIKA
  // ================================================================

  void _incrementPlayCount(int songId) {
    _playCounts[songId] = (_playCounts[songId] ?? 0) + 1;
    _savePlayCounts();
  }

  // ================================================================
  // ALVÁSIDŐZÍTŐ
  // ================================================================

  void setSleepTimer(Duration duration) {
    cancelSleepTimer();

    _sleepTimerRemaining = duration;
    notifyListeners();

    // Percenként frissítjük a hátralévő időt
    _sleepTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sleepTimerRemaining != null) {
        _sleepTimerRemaining = _sleepTimerRemaining! - const Duration(seconds: 1);
        if (_sleepTimerRemaining!.inSeconds <= 0) {
          // Idő letelt
          audioPlayer.stop();
          cancelSleepTimer();
        }
        notifyListeners();
      }
    });

    _sleepTimer = Timer(duration, () {
      audioPlayer.stop();
      cancelSleepTimer();
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTickTimer?.cancel();
    _sleepTickTimer = null;
    _sleepTimerRemaining = null;
    notifyListeners();
  }

  // ================================================================
  // LEJÁTSZÁS
  // ================================================================

  Future<void> playSong(int index) async {
    final displayed = displayedSongs;
    if (displayed.isEmpty || index >= displayed.length) return;

    // Hallgatási számláló növelése
    _incrementPlayCount(displayed[index].id);

    // Queue feltöltése a jelenlegi listával
    _queue = List<SongModel>.from(displayed);
    _currentIndex = index;
    _currentPlayingSongId = displayed[index].id;
    _hasStartedPlaying = true;

    await _loadQueueToPlayer(index);
  }

  /// Queue betöltése a lejátszóba
  Future<void> _loadQueueToPlayer(int startIndex) async {
    final audioSources = _queue.map((song) {
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
        initialIndex: startIndex,
        initialPosition: Duration.zero,
      );
      audioPlayer.play();
    } catch (e) {
      if (kDebugMode) print("Hiba a lejátszás közben: $e");
    }
  }

  /// Queue sorrend módosítása (drag & drop)
  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);

    // Frissítsük a currentIndex-et
    if (_currentPlayingSongId != null) {
      _currentIndex = _queue.indexWhere((s) => s.id == _currentPlayingSongId);
    }
    notifyListeners();
  }

  /// Zene hozzáadása a queue végéhez
  void addToQueue(SongModel song) {
    if (!_queue.any((s) => s.id == song.id)) {
      _queue.add(song);
      notifyListeners();
    }
  }

  /// Zene eltávolítása a queue-ból
  void removeFromQueue(int index) {
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      if (_currentPlayingSongId != null) {
        _currentIndex = _queue.indexWhere((s) => s.id == _currentPlayingSongId);
      }
      notifyListeners();
    }
  }

  /// Zene beillesztése a következő lejátszandó helyre (az aktuális zene után)
  void playNext(SongModel song) {
    // Ha már benne van, vegyük ki és rakjuk az aktuális után
    _queue.removeWhere((s) => s.id == song.id);

    if (_currentPlayingSongId != null) {
      final currentIdx = _queue.indexWhere((s) => s.id == _currentPlayingSongId);
      if (currentIdx >= 0) {
        _queue.insert(currentIdx + 1, song);
      } else {
        _queue.insert(0, song);
      }
    } else {
      _queue.insert(0, song);
    }

    // currentIndex frissítése
    if (_currentPlayingSongId != null) {
      _currentIndex = _queue.indexWhere((s) => s.id == _currentPlayingSongId);
    }
    notifyListeners();
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

  Future<void> downloadYoutubeVideo(
    String url, {
    void Function(double progress, String status)? onProgress,
    void Function(String fileName)? onDone,
    void Function(String error)? onError,
  }) async {
    if (url.isEmpty) return;

    if (!_hasPermission) {
      await requestPermission();
      if (!_hasPermission) {
        onError?.call("Nincs tárhely engedély. Engedélyezd a beállításokban!");
        return;
      }
    }

    _isDownloading = true;
    notifyListeners();

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

    var yt = YoutubeExplode();

    try {
      onProgress?.call(0, "Adatok lekérése...");
      var video = await yt.videos.get(videoId).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception("Időtúllépés az adatok lekérésekor."),
      );

      onProgress?.call(0, "Adatfolyam keresése...");
      var manifest = await yt.videos.streamsClient.getManifest(videoId).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception("Időtúllépés az adatfolyam keresésekor."),
      );

      var audioStreamInfo = manifest.audioOnly.withHighestBitrate();
      var audioStream = yt.videos.streamsClient.get(audioStreamInfo);

      String safeTitle = video.title.replaceAll(RegExp(r'[\\/><:"|?*]'), '_');
      safeTitle = safeTitle.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (safeTitle.isEmpty) safeTitle = 'youtube_audio_$videoId';

      int totalBytes = audioStreamInfo.size.totalBytes;
      int downloadedBytes = 0;
      final List<int> allBytes = [];
      final Completer<void> completer = Completer<void>();

      onProgress?.call(0, "Letöltés: 0%");

      audioStream.listen(
        (List<int> chunk) {
          allBytes.addAll(chunk);
          downloadedBytes += chunk.length;

          double progress = totalBytes > 0 ? downloadedBytes / totalBytes : 0;
          String status = "Letöltés: ${(progress * 100).toStringAsFixed(0)}%";

          _downloadProgress = progress;
          _downloadStatus = status;
          notifyListeners();

          onProgress?.call(progress, status);
        },
        onDone: () async {
          try {
            if (allBytes.length < 1000) {
              throw Exception("Nem érkezett elegendő adat a szerverről.");
            }

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

            try {
              await _audioQuery.scanMedia('/storage/emulated/0/');
            } catch (_) {}

            await fetchSongs();

            onDone?.call("$safeTitle.m4a");
            if (!completer.isCompleted) completer.complete();
          } catch (e) {
            onError?.call(e.toString().replaceAll('Exception: ', ''));
            if (!completer.isCompleted) completer.completeError(e);
          }
        },
        onError: (error) {
          onError?.call(error.toString());
          if (!completer.isCompleted) completer.completeError(error);
        },
        cancelOnError: true,
      );

      await completer.future;

    } catch (e) {
      onError?.call(e.toString().replaceAll('Exception: ', ''));
    } finally {
      yt.close();
      _isDownloading = false;
      _downloadProgress = 0;
      _downloadStatus = "";
      notifyListeners();
    }
  }

  @override
  void dispose() {
    cancelSleepTimer();
    audioPlayer.dispose();
    super.dispose();
  }
}
