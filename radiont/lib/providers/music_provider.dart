import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    // Kifejezetten a Permission Handlerrel is megpróbáljuk
    var status = await Permission.storage.request();
    var audioStatus = await Permission.audio.request();
    
    if (status.isGranted || audioStatus.isGranted) {
      _hasPermission = true;
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

    // Kiszűrjük azokat a hangfájlokat, amik nem zenék (pl. rövid értesítéshangok)
    _songs = allSongs.where((song) => song.isMusic == true && song.duration != null && song.duration! > 30000).toList();

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
          artUri: null, // Opcionálisan beállítható, de fájlrendszerből bonyolultabb
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
      if (kDebugMode) {
        print("Hiba a lejátszás közben: $e");
      }
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
      // Ha nincs következő, akkor az elsőre ugrik ha nem shuffle
      if(!_isShuffleModeEnabled) {
          audioPlayer.seek(Duration.zero, index: 0);
          audioPlayer.play();
      }
    }
  }

  void previousSong() {
    if (audioPlayer.hasPrevious) {
      audioPlayer.seekToPrevious();
    } else {
      // Ha nincs előző, és az elsőn vagyunk, akkor csak elölről kezdi
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

  @override
  void dispose() {
    audioPlayer.dispose();
    super.dispose();
  }
}
