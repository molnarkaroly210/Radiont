import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_animations/simple_animations.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';

import 'api_service.dart';
import 'providers/music_provider.dart';
import 'screens/music_screen.dart';
import 'screens/download_webview_screen.dart';
import 'services/dns_service.dart';
import 'services/version_service.dart';
import 'services/sharing_service.dart';
import 'providers/theme_provider.dart';
import 'widgets/pressable_scale_widget.dart';
import 'package:on_audio_query/on_audio_query.dart';

const Duration kAppAnimationDuration = Duration(milliseconds: 500);

// =================================================================
// PROVIDEREK
// =================================================================

class RadioProvider extends ChangeNotifier {
  final SharedPreferences prefs;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final PageController pageController = PageController(viewportFraction: 0.8);

  List<RadioStation> _stations = [];
  int _currentIndex = 0;
  bool _swipeOnlyFavorites = false;
  bool _isLoading = true;
  double _systemVolume = 0.5;
  int? _lastProcessedIndex;
  bool _volumeControllerAvailable = false;

  bool get isLoading => _isLoading;
  List<RadioStation> get stations => _stations;
  List<RadioStation> get favoriteStations =>
      _stations.where((s) => s.isFavorite).toList();
  List<RadioStation> get activeStations =>
      _swipeOnlyFavorites ? favoriteStations : _stations;
  RadioStation get currentStation => activeStations.isEmpty
      ? RadioStation(
          id: '',
          name: 'Nincs állomás',
          streamUrl: '',
          imageUrl: 'assets/images/default_radio.png')
      : activeStations[_currentIndex];
  int get currentIndex => _currentIndex;
  bool get swipeOnlyFavorites => _swipeOnlyFavorites;
  AudioPlayer get audioPlayer => _audioPlayer;
  double get systemVolume => _systemVolume;

  RadioProvider(this.prefs) {
    _loadInitialData();
    _audioPlayer.playerStateStream.listen((state) {
      notifyListeners();
    });

    _initVolumeController();

    // Figyeli a lejátszási lista indexének változását (pl. értesítési sáv gombnyomásra)
    _audioPlayer.currentIndexStream.listen((index) {
      if (index != null && index != _lastProcessedIndex) {
        _lastProcessedIndex = index; // Megakadályozza a többszöri feldolgozást
        // A pageController-t a lejátszási lista aktuális indexéhez igazítjuk.
        // A setStationByIndex-t a pageController onPageChanged eseménye fogja meghívni.
        if (pageController.hasClients) {
          pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  Future<void> _initVolumeController() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _systemVolume = await VolumeController().getVolume();
        VolumeController().listener((volume) {
          _systemVolume = volume;
          notifyListeners();
        });
        _volumeControllerAvailable = true;
      }
    } catch (e) {
      debugPrint(
          "VolumeController inicializálási hiba (valószínűleg teljes újrafordítás kell): $e");
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    pageController.dispose();
    if (_volumeControllerAvailable) {
      try {
        VolumeController().removeListener();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    _isLoading = true;
    notifyListeners();
    _stations = await RadioBrowserApi().fetchStations();
    _loadSettings();
    _isLoading = false;
    notifyListeners();
    // Lejátszási lista beállítása az indításkor
    if (activeStations.isNotEmpty) {
      _updateAudioSource(play: false);
    }
  }

  void _loadSettings() {
    final favoriteIds = prefs.getStringList('favoriteStations') ?? [];
    for (var station in _stations) {
      if (favoriteIds.contains(station.id)) {
        station.isFavorite = true;
      }
    }
    _swipeOnlyFavorites = prefs.getBool('swipeOnlyFavorites') ?? false;
  }

  Future<void> toggleFavorite(String stationId) async {
    final station = _stations.firstWhere((s) => s.id == stationId,
        orElse: () => currentStation);
    if (station.id.isEmpty) return;

    station.isFavorite = !station.isFavorite;
    final favoriteIds =
        _stations.where((s) => s.isFavorite).map((s) => s.id).toList();
    await prefs.setStringList('favoriteStations', favoriteIds);

    if (_swipeOnlyFavorites) {
      // Újraszámoljuk az indexet és frissítjük a lejátszási listát
      final oldStationId = currentStation.id;
      final newIndex = activeStations.indexWhere((s) => s.id == oldStationId);
      _currentIndex = (newIndex != -1) ? newIndex : 0;
      await _updateAudioSource(play: _audioPlayer.playing);
      pageController.jumpToPage(_currentIndex);
    }

    HapticFeedback.mediumImpact();
    notifyListeners();
  }

  Future<void> setStationByIndex(int index, {bool play = true}) async {
    if (activeStations.isEmpty || index < 0 || index >= activeStations.length) return;

    _currentIndex = index;
    notifyListeners();

    try {
      final stationToPlay = activeStations[_currentIndex];
      
      // Kényszerítjük a PageView-t az új indexre
      if (pageController.hasClients) {
        pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        );
      }

      if (stationToPlay.streamUrl.isNotEmpty) {
        // Mindig próbáljunk meg odaugrani az audio playlistben is
        if (_audioPlayer.currentIndex != index) {
          await _audioPlayer.seek(Duration.zero, index: index);
        }
        
        if (play) {
          await _audioPlayer.play();
        }
      }
    } catch (e) {
      debugPrint("Állomás beállítási hiba: $e");
    }
  }

  // Metódus a lejátszási lista (AudioSource) frissítésére
  Future<void> _updateAudioSource({bool play = true}) async {
    if (activeStations.isEmpty) {
      await _audioPlayer.stop();
      return;
    }

    final audioSources = List.generate(activeStations.length, (index) {
      final station = activeStations[index];
      final safeId = station.id.isNotEmpty ? station.id : 'radio_${station.name.replaceAll(RegExp(r'\s+'), '')}';
      return AudioSource.uri(
        Uri.parse(station.streamUrl),
        tag: MediaItem(
          id: '${safeId}_$index',
          album: "Radiont",
          title: station.name,
          artist: station.nowPlaying,
          artUri: Uri.parse(station.imageUrl),
        ),
      );
    });

    try {
      await _audioPlayer.setAudioSource(
        ConcatenatingAudioSource(children: audioSources),
        initialIndex: _currentIndex,
        initialPosition: Duration.zero,
      );
      // Mindig lehessen léptetni az értesítési sávban
      await _audioPlayer.setLoopMode(LoopMode.all);
      if (play) {
        _audioPlayer.play();
      }
    } catch (e) {
      debugPrint("Hiba az audio forrás beállításakor: $e");
    }
  }

  Future<void> setSwipeOnlyFavorites(bool value) async {
    final String oldStationId =
        activeStations.isNotEmpty ? currentStation.id : '';

    _swipeOnlyFavorites = value;
    await prefs.setBool('swipeOnlyFavorites', value);

    // Az új 'activeStations' lista alapján megkeressük az előzőleg hallgatott állomás új indexét
    int newIndex = activeStations.indexWhere((s) => s.id == oldStationId);

    if (newIndex == -1) {
      _currentIndex = 0;
    } else {
      _currentIndex = newIndex;
    }

    // Frissítjük a teljes lejátszási listát a háttérlejátszóban
    await _updateAudioSource(play: _audioPlayer.playing);

    notifyListeners();

    // A PageView-t az új indexre ugratjuk
    if (pageController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pageController.hasClients) {
          pageController.jumpToPage(_currentIndex);
        }
      });
    }
  }

  void nextStation() {
    if (activeStations.length < 2) return;
    int nextIndex = (_currentIndex + 1) % activeStations.length;
    pageController.animateToPage(nextIndex,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic);
  }

  void previousStation() {
    if (activeStations.length < 2) return;
    int prevIndex =
        (_currentIndex - 1 + activeStations.length) % activeStations.length;
    pageController.animateToPage(prevIndex,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic);
  }

  void togglePlayPause() {
    if (_audioPlayer.playing) {
      _audioPlayer.pause();
    } else {
      if (_audioPlayer.processingState == ProcessingState.ready) {
        _audioPlayer.play();
      } else if (_audioPlayer.processingState == ProcessingState.idle ||
          _audioPlayer.processingState == ProcessingState.completed) {
        // Ha a lejátszó leállt, újra beállítjuk az aktuális állomást a lejátszási listában
        setStationByIndex(_currentIndex);
      }
    }
  }

  void setSystemVolume(double volume) {
    _systemVolume = volume;
    if (_volumeControllerAvailable) {
      try {
        VolumeController().setVolume(volume);
      } catch (_) {}
    }
    notifyListeners();
  }
}

// =================================================================
// ALKALMAZÁS BELÉPÉSI PONTJA
// =================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Értesítési engedély kérése (Android 13+ esetén szükséges a vezérlőkhöz)
  if (Platform.isAndroid) {
    Permission.notification.request(); // Ne várjuk meg (await), hogy ne akadjon meg az indítás
  }

  // === PRIVÁT DNS BEÁLLÍTÁSA ===
  // Az alkalmazás saját DNS-feloldót használ (Cloudflare 1.1.1.1 DoH)
  // a telefon alapértelmezett DNS-e helyett.
  // Ez megkerüli az ISP/hálózati szintű DNS-blokkolásokat.
  HttpOverrides.global = PrivateDnsHttpOverrides();

  // === MÓDOSÍTÁS KEZDETE (KÉPERNYŐ FORGATÁS TILTÁSA) ===
  // Beállítjuk a preferált orientációt csak álló módra.
  // Ez megakadályozza, hogy az alkalmazás fekvő módba forduljon.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // === MÓDOSÍTÁS VÉGE ===

  // A just_audio_background szolgáltatás inicializálása a legújabb API szerint.
  // A vezérlőgombokat már nem kell manuálisan megadni, a csomag automatikusan kezeli őket.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.radiont.app.channel.audio',
    androidNotificationChannelName: 'Radiont Lejátszás',
    androidNotificationOngoing: true,
    androidNotificationIcon: 'mipmap/ic_launcher',
  );

  // SharingService inicializálása
  SharingService.init();

  final prefs = await SharedPreferences.getInstance();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider(prefs)),
        ChangeNotifierProvider(create: (_) => RadioProvider(prefs)),
        ChangeNotifierProvider(create: (_) => MusicProvider(prefs)),
      ],
      child: const RadiontApp(),
    ),
  );
}

class RadiontApp extends StatelessWidget {
  const RadiontApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      navigatorKey: SharingService.navigatorKey,
      title: 'Radiont',
      theme: themeProvider.getLightTheme(),
      darkTheme: themeProvider.getDarkTheme(),
      themeMode: themeProvider.themeMode,
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// =================================================================
// FŐ KÉPERNYŐ ÉS KOMPONENSEI
// =================================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  String _currentTime = '';
  Timer? _timer;

  void _toggleMode() {
    final musicProvider = context.read<MusicProvider>();
    final radioProvider = context.read<RadioProvider>();
    bool newMode = !musicProvider.isMusicModeActive;
    
    musicProvider.isMusicModeActive = newMode;
    if (newMode) {
      radioProvider.audioPlayer.stop();
    } else {
      musicProvider.audioPlayer.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    // Beállítjuk a kezdőképernyőt a beállítások alapján
    final themeProvider = context.read<ThemeProvider>();
    final initialMode = themeProvider.startScreen == 1;

    _updateTime();
    _timer =
        Timer.periodic(const Duration(seconds: 1), (Timer t) => _updateTime());

    // Verzióellenőrzés indításkor
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final musicProvider = context.read<MusicProvider>();
      musicProvider.isMusicModeActive = initialMode;
      VersionService.checkForUpdates(context);

      // Figyeljük a webes távirányítóról érkező letöltési kéréseket
      musicProvider.onWebDownloadRequest.listen((url) {
        if (mounted) {
          // Visszalépés a listára (bezárunk minden modal-t)
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
          
          // Biztosítjuk, hogy Zene módban legyünk
          if (!musicProvider.isMusicModeActive) {
            _toggleMode();
          }

          // Megnyitjuk a webview letöltő képernyőt
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DownloadWebViewScreen(
                sharedUrl: url,
                isWebDownload: true,
              ),
            ),
          );
        }
      });
    });
  }


  void _updateTime() {
    if (mounted) {
      setState(() => _currentTime = DateFormat('HH:mm').format(DateTime.now()));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _showFavoritesSheet() => showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const FavoritesSheet());

  @override
  Widget build(BuildContext context) {
    final musicProvider = context.watch<MusicProvider>();
    final radioProvider = context.watch<RadioProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stationsToDisplay = radioProvider.activeStations;
    final isMusicMode = musicProvider.isMusicModeActive;

    return Scaffold(
      body: Stack(
        children: [
          const AnimatedBackground(),
          // Radio Háttérkép
          if (!isMusicMode)
            Selector<RadioProvider, String>(
              selector: (_, provider) => provider.currentStation.imageUrl,
              builder: (context, imageUrl, child) {
                if (radioProvider.isLoading ||
                    radioProvider.stations.isEmpty ||
                    imageUrl.isEmpty) {
                  return const SizedBox.shrink();
                }
                return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 800),
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: Container(
                        key: ValueKey<String>(imageUrl),
                        decoration: BoxDecoration(
                            image: DecorationImage(
                                image: NetworkImage(imageUrl),
                                fit: BoxFit.cover)),
                        child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                            child: Container(
                                color: (isDark ? Colors.black : Colors.white)
                                    .withValues(alpha: isDark ? 0.6 : 0.2)))));
              },
            ),

          // Zene Háttérkép
          if (isMusicMode)
            Selector<MusicProvider, int?>(
              selector: (_, provider) => provider.currentSong?.id,
              builder: (context, songId, child) {
                if (songId == null) return const SizedBox.shrink();
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 1000),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: Stack(
                    key: ValueKey<int>(songId),
                    fit: StackFit.expand,
                    children: [
                      QueryArtworkWidget(
                        id: songId,
                        type: ArtworkType.AUDIO,
                        artworkFit: BoxFit.cover,
                        nullArtworkWidget: Container(color: Colors.transparent),
                        keepOldArtwork:
                            true, // Megtartja a régit amíg az új töltődik
                      ),
                      BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                        child: Container(
                          color: (isDark ? Colors.black : Colors.white)
                              .withValues(alpha: isDark ? 0.7 : 0.3),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),

          SafeArea(
            bottom: !themeProvider.isFullScreen,
            top: !themeProvider.isFullScreen,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: animation, child: child)),
              child: (radioProvider.isLoading && !isMusicMode)
                  ? Center(
                      key: const ValueKey('loader'),
                      child: LoadingAnimationWidget.staggeredDotsWave(
                        color: themeProvider.selectedColor,
                        size: 60,
                      ),
                    )
                  : Column(
                      key: const ValueKey('content'),
                      children: [
                        if (themeProvider.isFullScreen)
                          const SizedBox(height: 10),
                        TopBar(
                          currentTime: _currentTime,
                          isMusicMode: isMusicMode,
                          onToggleMode: _toggleMode,
                          onDownload: () async {
                            await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const DownloadWebViewScreen()));
                            // WebView-ból visszatérés után frissítjük a zenélistát
                            if (context.mounted) {
                              context.read<MusicProvider>().fetchSongs();
                            }
                          },
                        ),
                        Expanded(
                          child: isMusicMode
                              ? const MusicScreen()
                              : (stationsToDisplay.isEmpty
                                  ? Center(
                                      child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 40.0),
                                          child: Text(
                                              "Nincsenek kedvenceid.\nKapcsold ki a \"Csak a kedvencek lapozása\" opciót a beállításokban, vagy adj hozzá állomásokat a szív ikonnal.",
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium)))
                                  : PageView.builder(
                                      controller: radioProvider.pageController,
                                      itemCount: stationsToDisplay.length,
                                      onPageChanged: (index) {
                                        // Itt már nem kell lejátszást indítani, csak az állapotot frissíteni.
                                        // A setStationByIndex kezeli a lejátszó belső állapotának (seek) frissítését.
                                        radioProvider.setStationByIndex(index,
                                            play: radioProvider
                                                .audioPlayer.playing);
                                      },
                                      itemBuilder: (context, index) {
                                        final station =
                                            stationsToDisplay[index];
                                        return AnimatedBuilder(
                                          animation:
                                              radioProvider.pageController,
                                          builder: (context, child) {
                                            double value = 1.0;
                                            if (radioProvider.pageController
                                                .position.haveDimensions) {
                                              value = (radioProvider
                                                          .pageController
                                                          .page ??
                                                      0.0) -
                                                  index;
                                              value = (1 - (value.abs() * 0.4))
                                                  .clamp(0.0, 1.0);
                                            }
                                            return Center(
                                                child: Transform.scale(
                                                    scale: value,
                                                    child: Opacity(
                                                        opacity: value * value,
                                                        child: child)));
                                          },
                                          child: RadioCard(station: station),
                                        );
                                      },
                                    )),
                        ),
                        if (!isMusicMode)
                          GestureDetector(
                              onVerticalDragEnd: (details) {
                                if (details.primaryVelocity != null &&
                                    details.primaryVelocity! < -500) {
                                  _showFavoritesSheet();
                                }
                              },
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                        width: 40,
                                        height: 5,
                                        margin:
                                            const EdgeInsets.only(bottom: 10),
                                        decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.3),
                                            borderRadius:
                                                BorderRadius.circular(10))),
                                    const PlayerControls()
                                  ])),
                        const SizedBox(height: 16),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// =================================================================
// EGYÉB WIDGETEK (Változatlan)
// =================================================================

class RadioCard extends StatelessWidget {
  final RadioStation station;
  const RadioCard({super.key, required this.station});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
        aspectRatio: 1,
        child: AnimatedContainer(
            duration: kAppAnimationDuration,
            curve: Curves.easeInOut,
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                image: DecorationImage(
                    image: NetworkImage(station.imageUrl), fit: BoxFit.cover),
                boxShadow: [
                  BoxShadow(
                      color: theme.primaryColor.withValues(alpha: 0.6),
                      blurRadius: 30,
                      spreadRadius: 0,
                      offset: const Offset(0, 10)),
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 25,
                      spreadRadius: -5,
                      offset: const Offset(0, 15))
                ])));
  }
}

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    final radioProvider = context.watch<RadioProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final station = radioProvider.currentStation;
    final playerState = radioProvider.audioPlayer.playerState;
    final isPlaying = playerState.playing;
    final processingState = playerState.processingState;
    final theme = Theme.of(context);

    Widget playPauseButton() {
      final buttonColor =
          themeProvider.playButtonBlack ? Colors.black : Colors.white;

      if (processingState == ProcessingState.loading ||
          processingState == ProcessingState.buffering) {
        return AnimatedContainer(
          duration: kAppAnimationDuration,
          width: 70,
          height: 70,
          decoration:
              BoxDecoration(color: theme.primaryColor, shape: BoxShape.circle),
          child: Center(
            child: LoadingAnimationWidget.staggeredDotsWave(
              color: buttonColor,
              size: 40,
            ),
          ),
        );
      } else {
        return PressableScaleWidget(
          onTap: radioProvider.togglePlayPause,
          child: AnimatedContainer(
            duration: kAppAnimationDuration,
            width: 70,
            height: 70,
            decoration: BoxDecoration(
                color: theme.primaryColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: theme.primaryColor.withValues(alpha: 0.7),
                      blurRadius: 20,
                      spreadRadius: 2)
                ]),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child));
              },
              child: Icon(
                  key: ValueKey<bool>(isPlaying),
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 45,
                  color: buttonColor),
            ),
          ),
        );
      }
    }

    return GlassmorphicContainer(
        width: double.infinity,
        height: 260,
        margin: const EdgeInsets.symmetric(horizontal: 20),
        borderRadius: 40,
        blur: 20,
        border: 1.5,
        linearGradient: LinearGradient(colors: [
          theme.colorScheme.surface.withValues(alpha: 0.15),
          theme.colorScheme.surface.withValues(alpha: 0.05)
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderGradient: LinearGradient(colors: [
          theme.primaryColor.withValues(alpha: 0.5),
          theme.colorScheme.surface.withValues(alpha: 0.1)
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 25.0, vertical: 20.0),
            child: radioProvider.activeStations.isEmpty
                ? Center(
                    child: Text("Nincs lejátszható állomás",
                        style: theme.textTheme.titleMedium))
                : Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(
                                      station.name,
                                      style: theme.textTheme.headlineMedium,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      station.nowPlaying,
                                      style: theme.textTheme.bodyMedium,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ])),
                              const SizedBox(width: 15),
                              PressableScaleWidget(
                                onTap: () =>
                                    radioProvider.toggleFavorite(station.id),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 350),
                                  transitionBuilder: (child, animation) =>
                                      ScaleTransition(
                                    scale: animation.drive(
                                        Tween(begin: 0.0, end: 1.0).chain(
                                            CurveTween(
                                                curve: Curves.elasticOut))),
                                    child: child,
                                  ),
                                  child: Icon(
                                      key: ValueKey<bool>(station.isFavorite),
                                      station.isFavorite
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color: station.isFavorite
                                          ? const Color(0xFFE91E63)
                                          : theme.primaryColor,
                                      size: 30),
                                ),
                              )
                            ]),
                        const SizedBox(height: 10),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              PressableScaleWidget(
                                  child: IconButton(
                                      icon: const Icon(
                                          Icons.skip_previous_rounded),
                                      onPressed: radioProvider.previousStation,
                                      iconSize: 38,
                                      color: theme.iconTheme.color
                                          ?.withValues(alpha: 0.8))),
                              playPauseButton(),
                              PressableScaleWidget(
                                  child: IconButton(
                                      icon: const Icon(Icons.skip_next_rounded),
                                      onPressed: radioProvider.nextStation,
                                      iconSize: 38,
                                      color: theme.iconTheme.color
                                          ?.withValues(alpha: 0.8)))
                            ]),
                        Row(children: [
                          Icon(Icons.volume_mute_rounded,
                              size: 22,
                              color: theme.iconTheme.color
                                  ?.withValues(alpha: 0.6)),
                          Expanded(
                              child: Slider(
                                  value: radioProvider.systemVolume,
                                  onChanged: radioProvider.setSystemVolume,
                                  activeColor: theme.primaryColor,
                                  inactiveColor: theme
                                      .colorScheme.surfaceContainerHighest)),
                          Icon(Icons.volume_up_rounded,
                              size: 22,
                              color:
                                  theme.iconTheme.color?.withValues(alpha: 0.6))
                        ])
                      ])));
  }
}

class AnimatedListItem extends StatefulWidget {
  final Widget child;
  final int index;

  const AnimatedListItem({super.key, required this.child, required this.index});

  @override
  State<AnimatedListItem> createState() => _AnimatedListItemState();
}

class _AnimatedListItemState extends State<AnimatedListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _offsetAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    final curve =
        CurvedAnimation(parent: _controller, curve: Curves.decelerate);
    _offsetAnimation =
        Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
            .animate(curve);
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(curve);

    Timer(Duration(milliseconds: widget.index * 70), () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _offsetAnimation,
        child: widget.child,
      ),
    );
  }
}

class AllStationsSheet extends StatefulWidget {
  const AllStationsSheet({super.key});
  @override
  State<AllStationsSheet> createState() => _AllStationsSheetState();
}

class _AllStationsSheetState extends State<AllStationsSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  late List<RadioStation> _filteredStations;

  @override
  void initState() {
    super.initState();
    _filteredStations = context.read<RadioProvider>().stations;
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
        _filterStations();
      });
    });
  }

  void _filterStations() {
    final stations = context.read<RadioProvider>().stations;
    if (_searchQuery.isEmpty) {
      _filteredStations = stations;
    } else {
      _filteredStations = stations.where((station) {
        return station.name.toLowerCase().contains(_searchQuery) ||
            station.nowPlaying.toLowerCase().contains(_searchQuery);
      }).toList();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radioProvider = context.watch<RadioProvider>();
    final theme = Theme.of(context);

    return GlassmorphicContainer(
        width: double.infinity,
        height: MediaQuery.of(context).size.height * 0.8,
        borderRadius: 30,
        blur: 20,
        border: 1,
        linearGradient: BottomSheetStyles.glassGradient(context),
        borderGradient: BottomSheetStyles.glassBorderGradient(context),
        child: Column(children: [
          Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.symmetric(vertical: 15),
              decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10))),
          Text("Összes Állomás", style: theme.textTheme.titleLarge),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20.0, vertical: 15.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Keresés...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none),
                filled: true,
                fillColor: theme.colorScheme.surface.withValues(alpha: 0.2),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
              child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _filteredStations.length,
                  itemBuilder: (context, index) {
                    final station = _filteredStations[index];
                    final bool isCurrentlyPlaying =
                        radioProvider.currentStation.id == station.id &&
                            radioProvider.audioPlayer.playing;
                    return AnimatedListItem(
                      index: index,
                      child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 8),
                          leading: CircleAvatar(
                              radius: 25,
                              backgroundImage: NetworkImage(station.imageUrl),
                              onBackgroundImageError: (e, s) => {},
                              child: Image.asset(
                                  'assets/images/default_radio.png')),
                          title: Text(station.name,
                              style: theme.textTheme.titleMedium),
                          subtitle: Text(station.nowPlaying,
                              style: theme.textTheme.bodyMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          trailing: isCurrentlyPlaying
                              ? Icon(Icons.bar_chart_rounded,
                                  color: theme.primaryColor)
                              : PressableScaleWidget(
                                  child: IconButton(
                                      icon: Icon(
                                          Icons.play_circle_outline_rounded,
                                          color: theme.primaryColor
                                              .withValues(alpha: 0.7),
                                          size: 30),
                                      onPressed: () async {
                                        await context
                                            .read<RadioProvider>()
                                            .setSwipeOnlyFavorites(false);
                                        if (!context.mounted) return;
                                        final newIndex = radioProvider.stations
                                            .indexWhere(
                                                (s) => s.id == station.id);
                                        if (newIndex != -1) {
                                          radioProvider.pageController
                                              .jumpToPage(newIndex);
                                        }
                                        Navigator.pop(context);
                                      })),
                          onTap: () async {
                            await context
                                .read<RadioProvider>()
                                .setSwipeOnlyFavorites(false);
                            if (!context.mounted) return;
                            final newIndex = radioProvider.stations
                                .indexWhere((s) => s.id == station.id);
                            if (newIndex != -1) {
                              radioProvider.pageController.jumpToPage(newIndex);
                            }
                            Navigator.pop(context);
                          }),
                    );
                  }))
        ]));
  }
}

class FavoritesSheet extends StatefulWidget {
  const FavoritesSheet({super.key});
  @override
  State<FavoritesSheet> createState() => _FavoritesSheetState();
}

class _FavoritesSheetState extends State<FavoritesSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  late List<RadioStation> _filteredFavorites;

  @override
  void initState() {
    super.initState();
    _filteredFavorites = context.read<RadioProvider>().favoriteStations;
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
        _filterFavorites();
      });
    });
  }

  void _filterFavorites() {
    final favorites = context.read<RadioProvider>().favoriteStations;
    if (_searchQuery.isEmpty) {
      _filteredFavorites = favorites;
    } else {
      _filteredFavorites = favorites.where((station) {
        return station.name.toLowerCase().contains(_searchQuery) ||
            station.nowPlaying.toLowerCase().contains(_searchQuery);
      }).toList();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radioProvider = context.watch<RadioProvider>();
    final favorites = _filteredFavorites;
    final theme = Theme.of(context);

    return GlassmorphicContainer(
        width: double.infinity,
        height: MediaQuery.of(context).size.height * 0.65,
        borderRadius: 30,
        blur: 20,
        border: 1,
        linearGradient: BottomSheetStyles.glassGradient(context),
        borderGradient: BottomSheetStyles.glassBorderGradient(context),
        child: Column(children: [
          Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.symmetric(vertical: 15),
              decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10))),
          Text("Kedvencek", style: theme.textTheme.titleLarge),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20.0, vertical: 15.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Keresés...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none),
                filled: true,
                fillColor: theme.colorScheme.surface.withValues(alpha: 0.2),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
              child: favorites.isEmpty
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40.0),
                          child: Text(
                              "Még nincsenek kedvenceid.\nA lejátszón a szív ikonnal adhatsz hozzá állomásokat.",
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: favorites.length,
                      itemBuilder: (context, index) {
                        final station = favorites[index];
                        return AnimatedListItem(
                          index: index,
                          child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 8),
                              leading: CircleAvatar(
                                  radius: 25,
                                  backgroundImage:
                                      NetworkImage(station.imageUrl)),
                              title: Text(station.name,
                                  style: theme.textTheme.titleMedium),
                              subtitle: Text(station.nowPlaying,
                                  style: theme.textTheme.bodyMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              trailing: PressableScaleWidget(
                                  child: IconButton(
                                      icon: Icon(Icons.play_circle_fill_rounded,
                                          color: theme.primaryColor, size: 30),
                                      onPressed: () async {
                                        await context
                                            .read<RadioProvider>()
                                            .setSwipeOnlyFavorites(true);
                                        if (!context.mounted) return;
                                        final newIndex = radioProvider
                                            .favoriteStations
                                            .indexWhere(
                                                (s) => s.id == station.id);
                                        if (newIndex != -1) {
                                          radioProvider.pageController
                                              .jumpToPage(newIndex);
                                        }
                                        Navigator.pop(context);
                                      }))),
                        );
                      }))
        ]));
  }
}

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final radioProvider = context.watch<RadioProvider>();
    final musicProvider = context.watch<MusicProvider>();
    final theme = Theme.of(context);

    return GlassmorphicContainer(
        width: double.infinity,
        height: MediaQuery.of(context).size.height * 0.85,
        borderRadius: 30,
        blur: 20,
        border: 1,
        alignment: Alignment.center,
        linearGradient: BottomSheetStyles.glassGradient(context),
        borderGradient: BottomSheetStyles.glassBorderGradient(context),
        child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 15.0, vertical: 20.0),
            child: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Center(
                      child: Text("Beállítások",
                          style: theme.textTheme.titleLarge)),
                  const SizedBox(height: 20),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0),
                      child: Text("Megjelenés",
                          style: theme.textTheme.titleMedium)),
                  const SizedBox(height: 10),
                  SegmentedButton<ThemeMode>(
                      segments: const <ButtonSegment<ThemeMode>>[
                        ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            label: Text('Világos'),
                            icon: Icon(Icons.wb_sunny_outlined)),
                        ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            label: Text('Sötét'),
                            icon: Icon(Icons.nightlight_outlined)),
                        ButtonSegment<ThemeMode>(
                            value: ThemeMode.system,
                            label: Text('Rendszer'),
                            icon: Icon(Icons.brightness_auto_outlined))
                      ],
                      selected: {
                        themeProvider.themeMode
                      },
                      onSelectionChanged: (s) =>
                          themeProvider.setThemeMode(s.first),
                      style: _segmentedButtonStyle(context)),
                  const SizedBox(height: 20),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0),
                      child: Text("Induló képernyő",
                          style: theme.textTheme.titleMedium)),
                  const SizedBox(height: 10),
                  SegmentedButton<int>(
                      segments: const <ButtonSegment<int>>[
                        ButtonSegment<int>(
                            value: 0,
                            label: Text('Rádió'),
                            icon: Icon(Icons.radio_rounded)),
                        ButtonSegment<int>(
                            value: 1,
                            label: Text('Zene'),
                            icon: Icon(Icons.music_note_rounded)),
                      ],
                      selected: {themeProvider.startScreen},
                      onSelectionChanged: (s) =>
                          themeProvider.setStartScreen(s.first),
                      style: _segmentedButtonStyle(context)),
                  const SizedBox(height: 10),
                  SwitchListTile(
                      title: Text("Teljes képernyő",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text("Elrejti a rendszer állapotsávját",
                          style: theme.textTheme.bodyMedium),
                      value: themeProvider.isFullScreen,
                      onChanged: themeProvider.setFullScreen,
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  const Divider(height: 25, thickness: 0.5),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0),
                      child: Text("Lejátszás",
                          style: theme.textTheme.titleMedium)),
                  SwitchListTile(
                      title: Text("Képernyő ébren tartása",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text("Megakadályozza a képernyő kikapcsolását",
                          style: theme.textTheme.bodyMedium),
                      value: themeProvider.isAlwaysOn,
                      onChanged: themeProvider.setAlwaysOn,
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  SwitchListTile(
                      title: Text("Csak a kedvencek lapozása",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text(
                          "A főképernyőn csak a kedvencek jelennek meg",
                          style: theme.textTheme.bodyMedium),
                      value: radioProvider.swipeOnlyFavorites,
                      onChanged: radioProvider.setSwipeOnlyFavorites,
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  if (!themeProvider.backgroundPlayback)
                    SwitchListTile(
                      title: Text("Lejátszás a háttérben",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text("Engedélyezi a folyamatos lejátszást",
                          style: theme.textTheme.bodyMedium),
                      value: themeProvider.backgroundPlayback,
                      onChanged: (bool value) async {
                        if (value) {
                          await showDialog(
                            context: context,
                            barrierColor: Colors.black.withValues(alpha: 0.4),
                            builder: (BuildContext dialogContext) {
                              return BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                                child: Dialog(
                                  backgroundColor: Colors.transparent,
                                  elevation: 0,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(30),
                                      gradient:
                                          BottomSheetStyles.glassBorderGradient(
                                              dialogContext),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(1.5),
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(28.5),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            gradient:
                                                BottomSheetStyles.glassGradient(
                                                    dialogContext),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                                25, 25, 25, 20),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                    "Háttérben történő lejátszás",
                                                    style: theme
                                                        .textTheme.titleLarge),
                                                const SizedBox(height: 15),
                                                Text(
                                                    "A folyamatos lejátszás biztosításához az alkalmazás akkumulátorhasználati beállítását 'Nincs korlátozva' opcióra kell állítani.\n\nAz 'OK' gombra kattintva átirányítjuk az alkalmazás beállításaihoz, ahol ezt manuálisan megteheti.",
                                                    style: theme
                                                        .textTheme.bodyMedium),
                                                const SizedBox(height: 20),
                                                Align(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: TextButton(
                                                    style: TextButton.styleFrom(
                                                      foregroundColor:
                                                          theme.primaryColor,
                                                    ),
                                                    child: Text("OK",
                                                        style: theme.textTheme
                                                            .labelLarge
                                                            ?.copyWith(
                                                                color: theme
                                                                    .primaryColor,
                                                                fontSize: 16)),
                                                    onPressed: () {
                                                      Navigator.of(
                                                              dialogContext)
                                                          .pop();
                                                      openAppSettings();
                                                      themeProvider
                                                          .setBackgroundPlayback(
                                                              true);
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        }
                      },
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  const Divider(height: 25, thickness: 0.5),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0),
                      child: Text("Hálózati megosztás",
                          style: theme.textTheme.titleMedium)),
                  SwitchListTile(
                      title: Text("Webes streaming szerver",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text(
                          musicProvider.isStreamingEnabled
                              ? "Cím: ${musicProvider.streamingUrl}"
                              : "Zenék elérése böngészőből a helyi hálózaton",
                          style: theme.textTheme.bodyMedium),
                      value: musicProvider.isStreamingEnabled,
                      onChanged: (_) => musicProvider.toggleStreaming(radioProvider, themeProvider),
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  SwitchListTile(
                      title: Text("PIN védelem",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text("Jelszó kérése a webes felületen",
                          style: theme.textTheme.bodyMedium),
                      value: musicProvider.isStreamingPinEnabled,
                      onChanged: (val) => musicProvider.setStreamingPinEnabled(val, radioProvider, themeProvider),
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  if (musicProvider.isStreamingPinEnabled)
                    ListTile(
                      title: const Text("PIN kód beállítása"),
                      subtitle: Text("Jelenlegi: ${musicProvider.streamingPin}"),
                      leading: Icon(Icons.password_rounded, color: theme.primaryColor, size: 22),
                      trailing: const Icon(Icons.edit_rounded, size: 18),
                      onTap: () async {
                        final controller = TextEditingController(text: musicProvider.streamingPin);
                        await showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text("PIN kód beállítása"),
                            content: TextField(
                              controller: controller,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                              decoration: const InputDecoration(labelText: "PIN (4-6 számjegy)", hintText: "1234"),
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Mégse")),
                              ElevatedButton(
                                onPressed: () {
                                  if (controller.text.length >= 4) {
                                    musicProvider.setStreamingPin(controller.text, radioProvider, themeProvider);
                                    Navigator.pop(ctx);
                                  }
                                },
                                child: const Text("Mentés"),
                              ),
                            ],
                          ),
                        );
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  if (musicProvider.isStreamingPinEnabled)
                    SwitchListTile(
                        title: Text("Vendég mód engedélyezése",
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.normal)),
                        subtitle: Text("Hallgatás engedélyezése PIN nélkül",
                            style: theme.textTheme.bodyMedium),
                        value: musicProvider.isStreamingGuestModeEnabled,
                        onChanged: (val) => musicProvider.setStreamingGuestModeEnabled(val, radioProvider, themeProvider),
                        activeThumbColor: theme.primaryColor,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 10)),
                  if (musicProvider.isStreamingEnabled)
                    Padding(
                      padding: const EdgeInsets.only(left: 10, bottom: 10),
                      child: PressableScaleWidget(
                        child: TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                                text: musicProvider.streamingUrl ?? ""));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("Cím másolva a vágólapra"),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: Icon(Icons.copy_rounded,
                              size: 18, color: theme.primaryColor),
                          label: Text("Cím másolása",
                              style: TextStyle(color: theme.primaryColor)),
                        ),
                      ),
                    ),
                  SwitchListTile(
                      title: Text("YouTube Link Bedobó",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text("YouTube linkek fogadása a webes felületről",
                          style: theme.textTheme.bodyMedium),
                      value: musicProvider.isWebRemoteDownloadEnabled,
                      onChanged: (val) async {
                        if (val) {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text("Figyelem"),
                              content: const Text("A webes letöltő csak akkor elérhető, ha az alkalmazás nyitva van a Zene fülön, és a kijelző be van kapcsolva.\n\nBekapcsolás esetén a telefon képernyője folyamatosan ébren marad. Biztosan bekapcsolod?"),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Mégse")),
                                ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Bekapcsolás")),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            musicProvider.setWebRemoteDownloadEnabled(true);
                          }
                        } else {
                          musicProvider.setWebRemoteDownloadEnabled(false);
                        }
                      },
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  const Divider(height: 25, thickness: 0.5),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0),
                      child:
                          Text("Neonszín", style: theme.textTheme.titleMedium)),
                  const SizedBox(height: 20),
                  Column(
                    children: [
                      Container(
                        height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(25),
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFFff0000),
                              Color(0xFFFFFF00),
                              Color(0xFF00FF00),
                              Color(0xFF00FFFF),
                              Color(0xFF0000FF),
                              Color(0xFFFF00FF),
                              Color(0xFFff0000)
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Slider(
                        value: themeProvider.selectedColor.computeHue,
                        min: 0,
                        max: 360,
                        divisions: 360,
                        onChanged: (value) {
                          final color =
                              HSVColor.fromAHSV(1.0, value, 1.0, 1.0).toColor();
                          themeProvider.setThemeColor(color);
                        },
                        activeColor: themeProvider.selectedColor,
                        inactiveColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 20),
                      AnimatedContainer(
                        duration: kAppAnimationDuration,
                        curve: Curves.easeInOut,
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                            color: themeProvider.selectedColor,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                  color: themeProvider.selectedColor
                                      .withValues(alpha: 0.7),
                                  blurRadius: 15,
                                  spreadRadius: 3)
                            ]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SwitchListTile(
                      title: Text("Lejátszás gomb fekete",
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.normal)),
                      subtitle: Text("Alapértelmezetten fehér",
                          style: theme.textTheme.bodyMedium),
                      value: themeProvider.playButtonBlack,
                      onChanged: themeProvider.setPlayButtonBlack,
                      activeThumbColor: theme.primaryColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10)),
                  const Divider(height: 25, thickness: 0.5),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0),
                      child: Text("Privát DNS",
                          style: theme.textTheme.titleMedium)),
                  const SizedBox(height: 5),
                  Padding(
                    padding: const EdgeInsets.only(left: 10.0),
                    child: Text(
                      "Az alkalmazás saját DNS-feloldót használ a hálózati szűrők megkerüléséhez.",
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 10),
                  RadioListTile<String>(
                    title: Text("dns.adguard.com",
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.normal)),
                    subtitle: Text("Alapértelmezett AdGuard DNS",
                        style: theme.textTheme.bodyMedium),
                    value: DnsService.adguardDefault,
                    groupValue: themeProvider.dnsProvider,
                    onChanged: (value) {
                      if (value != null) {
                        themeProvider.setDnsProvider(value);
                      }
                    },
                    activeColor: theme.primaryColor,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  RadioListTile<String>(
                    title: Text("dns.adguard-dns.com",
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.normal)),
                    subtitle: Text("Alternatív AdGuard DNS",
                        style: theme.textTheme.bodyMedium),
                    value: DnsService.adguardDns,
                    groupValue: themeProvider.dnsProvider,
                    onChanged: (value) {
                      if (value != null) {
                        themeProvider.setDnsProvider(value);
                      }
                    },
                    activeColor: theme.primaryColor,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  // === LISTA SUHINTÁSI BEÁLLÍTÁSOK ===
                  Builder(builder: (context) {
                    final mp = context.watch<MusicProvider>();

                    String getActionName(String action) {
                      switch (action) {
                        case 'archive':
                          return 'Archiválás';
                        case 'delete':
                          return 'Törlés';
                        case 'play_next':
                          return 'Lejátszás következőként';
                        case 'add_to_queue':
                          return 'Felvétel a sorra';
                        case 'play':
                          return 'Zene indítása';
                        case 'edit_title':
                          return 'Cím szerkesztés';
                        case 'add_to_album':
                          return 'Albumhoz adás';
                        case 'edit_tags':
                          return 'Címke szerkesztés';
                        case 'details':
                          return 'Részletek';
                        case 'none':
                        default:
                          return 'Semmi';
                      }
                    }

                    const items = [
                      DropdownMenuItem(
                          value: 'archive', child: Text("Archiválás")),
                      DropdownMenuItem(value: 'delete', child: Text("Törlés")),
                      DropdownMenuItem(
                          value: 'play_next', child: Text("Következőként")),
                      DropdownMenuItem(
                          value: 'add_to_queue',
                          child: Text("Felvétel a sorra")),
                      DropdownMenuItem(
                          value: 'play', child: Text("Zene indítása")),
                      DropdownMenuItem(
                          value: 'edit_title', child: Text("Cím szerkesztés")),
                      DropdownMenuItem(
                          value: 'add_to_album', child: Text("Albumhoz adás")),
                      DropdownMenuItem(
                          value: 'edit_tags', child: Text("Címke szerkesztés")),
                      DropdownMenuItem(
                          value: 'details', child: Text("Részletek")),
                      DropdownMenuItem(value: 'none', child: Text("Semmi")),
                    ];

                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 25, thickness: 0.5),
                          Padding(
                              padding:
                                  const EdgeInsets.only(left: 10, bottom: 8),
                              child: Text("Lista gesztusok",
                                  style: theme.textTheme.titleMedium)),
                          ListTile(
                            dense: true,
                            leading: Icon(Icons.swipe_right_rounded,
                                color: theme.primaryColor, size: 22),
                            title: const Text("Jobbra húzás a listában"),
                            subtitle:
                                Text(getActionName(mp.listSwipeRightAction)),
                            trailing: DropdownButton<String>(
                              value: mp.listSwipeRightAction,
                              underline: const SizedBox(),
                              items: items,
                              onChanged: (val) =>
                                  mp.setListSwipeAction(true, val!),
                            ),
                          ),
                          ListTile(
                            dense: true,
                            leading: Icon(Icons.swipe_left_rounded,
                                color: theme.primaryColor, size: 22),
                            title: const Text("Balra húzás a listában"),
                            subtitle:
                                Text(getActionName(mp.listSwipeLeftAction)),
                            trailing: DropdownButton<String>(
                              value: mp.listSwipeLeftAction,
                              underline: const SizedBox(),
                              items: items,
                              onChanged: (val) =>
                                  mp.setListSwipeAction(false, val!),
                            ),
                          ),
                        ]);
                  }),
                  // === CÍMKÉK KEZELÉSE ===
                  Builder(builder: (context) {
                    final mp = context.watch<MusicProvider>();
                    final tags = mp.allTags;
                    if (tags.isEmpty) return const SizedBox.shrink();
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 25, thickness: 0.5),
                          ExpansionTile(
                            tilePadding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            leading: Icon(Icons.label_outline,
                                color: theme.primaryColor, size: 22),
                            title: Text("Címkék kezelése",
                                style: theme.textTheme.titleMedium),
                            subtitle: Text("${tags.length} címke",
                                style: theme.textTheme.bodySmall),
                            children: tags.map((tag) {
                              final pinned = mp.pinnedTags.contains(tag);
                              final count = mp.songsWithTag(tag).length;
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                    pinned ? Icons.push_pin : Icons.label,
                                    color: pinned
                                        ? theme.primaryColor
                                        : theme.iconTheme.color
                                            ?.withValues(alpha: 0.5),
                                    size: 20),
                                title: Text(tag,
                                    style: theme.textTheme.titleSmall),
                                subtitle: Text("$count zene",
                                    style: theme.textTheme.bodySmall),
                                trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Icon(
                                            pinned
                                                ? Icons.push_pin
                                                : Icons.push_pin_outlined,
                                            color: pinned
                                                ? theme.primaryColor
                                                : theme.iconTheme.color
                                                    ?.withValues(alpha: 0.4),
                                            size: 20),
                                        tooltip: pinned ? "Levétel" : "Kitűzés",
                                        onPressed: () => mp.togglePinTag(tag),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.delete_outline,
                                            color: Colors.red.shade300,
                                            size: 20),
                                        tooltip: "Törlés",
                                        onPressed: () {
                                          showDialog(
                                              context: context,
                                              barrierColor: Colors.black87,
                                              builder: (ctx) => AlertDialog(
                                                    backgroundColor:
                                                        Color.alphaBlend(
                                                            theme.colorScheme
                                                                .surface
                                                                .withValues(
                                                                    alpha:
                                                                        0.97),
                                                            Colors.black),
                                                    shape:
                                                        RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        24)),
                                                    title: const Text(
                                                        "Címke törlése"),
                                                    content: Text(
                                                        "\"$tag\" címke törlése az összes zenéről?\n($count zene érintett)"),
                                                    actions: [
                                                      TextButton(
                                                          child: const Text(
                                                              "Mégse"),
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                  ctx)),
                                                      ElevatedButton(
                                                          style: ElevatedButton
                                                              .styleFrom(
                                                                  backgroundColor:
                                                                      Colors
                                                                          .red,
                                                                  foregroundColor:
                                                                      Colors
                                                                          .white),
                                                          child: const Text(
                                                              "Törlés"),
                                                          onPressed: () {
                                                            // Címke eltávolítása az összes zenéről
                                                            for (final s in mp
                                                                .songsWithTag(
                                                                    tag)) {
                                                              mp.removeTagFromSong(
                                                                  s.id, tag);
                                                            }
                                                            mp.unpinTag(tag);
                                                            Navigator.pop(ctx);
                                                          }),
                                                    ],
                                                  ));
                                        },
                                      ),
                                    ]),
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                              );
                            }).toList(),
                          ),
                        ]);
                  }),
                  // === EGYÉB BEÁLLÍTÁSOK ===
                  const Divider(height: 25, thickness: 0.5),
                  Padding(
                      padding: const EdgeInsets.only(left: 10.0, bottom: 5),
                      child: Text("Egyéb", style: theme.textTheme.titleMedium)),
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.system_update_rounded,
                        color: theme.primaryColor, size: 22),
                    title: const Text("Frissítések keresése"),
                    subtitle: const Text("Új verzió keresése a GitHubon"),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    onTap: () {
                      VersionService.checkForUpdates(context, showMessage: true);
                    },
                  ),
                  // === ARCHIVÁLT ZENÉK ===
                  Builder(builder: (context) {
                    final mp = context.watch<MusicProvider>();
                    final archived = mp.archivedSongs;
                    if (archived.isEmpty) return const SizedBox.shrink();
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 25, thickness: 0.5),
                          ExpansionTile(
                            tilePadding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            leading: Icon(Icons.archive_rounded,
                                color: theme.primaryColor, size: 22),
                            title: Text("Archivált zenék",
                                style: theme.textTheme.titleMedium),
                            subtitle: Text("${archived.length} zene elrejtve",
                                style: theme.textTheme.bodySmall),
                            children: archived
                                .map((song) => ListTile(
                                      dense: true,
                                      title: Text(mp.getSongTitle(song),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleSmall),
                                      subtitle: Text(mp.getSongArtist(song),
                                          style: theme.textTheme.bodySmall),
                                      trailing: TextButton.icon(
                                        icon: Icon(Icons.restore,
                                            size: 18,
                                            color: theme.primaryColor),
                                        label: Text("Visszaállítás",
                                            style: TextStyle(
                                                color: theme.primaryColor,
                                                fontSize: 12)),
                                        onPressed: () =>
                                            mp.unarchiveSong(song.id),
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 14),
                                    ))
                                .toList(),
                          ),
                        ]);
                  }),
                ]))));
  }

  ButtonStyle _segmentedButtonStyle(BuildContext context) {
    final theme = Theme.of(context);
    return ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return theme.primaryColor;
          }
          return theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.5);
        }),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return theme.colorScheme.onPrimary;
          }
          return theme.colorScheme.onSurface;
        }),
        enableFeedback: true,
        animationDuration: kAppAnimationDuration,
        shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8)));
  }
}

extension ColorHue on Color {
  double get computeHue {
    final hsl = HSLColor.fromColor(this);
    return hsl.hue;
  }
}

class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({super.key});
  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final primaryColor = themeProvider.selectedColor;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: primaryColor),
      duration: const Duration(seconds: 1),
      builder: (context, animatedColor, child) {
        return LoopAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(seconds: 40),
            builder: (context, value, _) => CustomPaint(
                painter:
                    BackgroundPainter(value, animatedColor ?? primaryColor),
                child: Container()));
      },
    );
  }
}

class BackgroundPainter extends CustomPainter {
  final double animationValue;
  final Color primaryColor;
  BackgroundPainter(this.animationValue, this.primaryColor);
  @override
  void paint(Canvas canvas, Size size) {
    final color1 = primaryColor;
    final color2 =
        HSLColor.fromColor(primaryColor).withLightness(0.7).toColor();
    const double blurAmount = 150.0;
    final paint1 = Paint()
      ..color = color1.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, blurAmount);
    final paint2 = Paint()
      ..color = color2.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, blurAmount);
    final paint3 = Paint()
      ..color = color1.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, blurAmount);
    final progress = animationValue * 2 * pi;
    final position1 = Offset(
        size.width * 0.5 + sin(progress) * size.width * 0.4,
        size.height * 0.5 + cos(progress) * size.height * 0.4);
    final position2 = Offset(
        size.width * 0.5 + cos(progress * 0.8) * size.width * 0.5,
        size.height * 0.2 + sin(progress * 0.8) * size.height * 0.3);
    final position3 = Offset(
        size.width * 0.2 + sin(progress * 1.2) * size.width * 0.3,
        size.height * 0.8 + cos(progress * 1.2) * size.height * 0.4);
    canvas.drawCircle(position1, size.width * 0.5, paint1);
    canvas.drawCircle(position2, size.width * 0.4, paint2);
    canvas.drawCircle(position3, size.width * 0.3, paint3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class GlassButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  const GlassButton({super.key, required this.onPressed, required this.icon});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PressableScaleWidget(
      onTap: onPressed,
      child: GlassmorphicContainer(
          width: 50,
          height: 50,
          borderRadius: 25,
          blur: 20,
          alignment: Alignment.center,
          border: 1,
          linearGradient: LinearGradient(colors: [
            theme.colorScheme.surface.withValues(alpha: 0.2),
            theme.colorScheme.surface.withValues(alpha: 0.1)
          ], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderGradient: LinearGradient(colors: [
            theme.primaryColor.withValues(alpha: 0.6),
            theme.colorScheme.surface.withValues(alpha: 0.2)
          ], begin: Alignment.topLeft, end: Alignment.bottomRight),
          child: Icon(icon, size: 24, color: theme.iconTheme.color)),
    );
  }
}

class TopBar extends StatefulWidget {
  final String currentTime;
  final bool isMusicMode;
  final VoidCallback onToggleMode;
  final VoidCallback onDownload;
  const TopBar({
    super.key,
    required this.currentTime,
    required this.isMusicMode,
    required this.onToggleMode,
    required this.onDownload,
  });

  @override
  State<TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<TopBar> with SingleTickerProviderStateMixin {
  bool _showUpdate = false;
  Timer? _toggleTimer;
  late AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    // 15 másodpercenként váltás: óra <-> update jelzés
    _toggleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && VersionService.updateAvailable) {
        setState(() => _showUpdate = !_showUpdate);
        // 3 másodpercig mutatjuk az update jelzést, utána vissza az órára
        if (_showUpdate) {
          Future.delayed(const Duration(seconds: 10), () {

            if (mounted) setState(() => _showUpdate = false);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _toggleTimer?.cancel();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          ListenableBuilder(
            listenable: Listenable.merge([
              VersionService.isDownloading,
              VersionService.isDownloadReady,
              VersionService.downloadProgress,
            ]),
            builder: (context, _) {
              final bool isDownloading = VersionService.isDownloading.value;
              final bool isDownloadReady = VersionService.isDownloadReady.value;
              final double progress = VersionService.downloadProgress.value;

              return GestureDetector(
                onTap: (_showUpdate || isDownloading || isDownloadReady)
                    ? () {
                        if (isDownloadReady) {
                          VersionService.installDownloadedApk();
                        } else {
                          VersionService.showUpdate(context);
                        }
                      }
                    : null,
                child: AnimatedContainer(
                    duration: kAppAnimationDuration,
                    width: 110,
                    height: 45,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    child: GlassmorphicContainer(
                        width: 110,
                        height: 45,
                        borderRadius: 25,
                        blur: 20,
                        alignment: Alignment.center,
                        border: 1,
                        linearGradient: LinearGradient(colors: [
                          isDownloadReady
                              ? Colors.green.withValues(alpha: 0.3)
                              : (isDownloading
                                  ? Colors.blue.withValues(alpha: 0.3)
                                  : (_showUpdate
                                      ? Colors.red.withValues(alpha: 0.3)
                                      : theme.colorScheme.surface.withValues(alpha: 0.2))),
                          isDownloadReady
                              ? Colors.green.withValues(alpha: 0.15)
                              : (isDownloading
                                  ? Colors.blue.withValues(alpha: 0.15)
                                  : (_showUpdate
                                      ? Colors.red.withValues(alpha: 0.15)
                                      : theme.colorScheme.surface.withValues(alpha: 0.1)))
                        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                        borderGradient: LinearGradient(colors: [
                          isDownloadReady
                              ? Colors.green.withValues(alpha: 0.8)
                              : (isDownloading
                                  ? Colors.blue.withValues(alpha: 0.8)
                                  : (_showUpdate
                                      ? Colors.red.withValues(alpha: 0.8)
                                      : theme.primaryColor.withValues(alpha: 0.6))),
                          theme.colorScheme.surface.withValues(alpha: 0.2)
                        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: (_showUpdate || isDownloading || isDownloadReady)
                              ? FadeTransition(
                                  key: const ValueKey('update'),
                                  opacity: _blinkController,
                                  child: () {
                                    // Szín és ikon meghatározása az állapot alapján
                                    Color statusColor = Colors.red;
                                    IconData statusIcon = Icons.warning_rounded;
                                    String statusText = "UPDATE";

                                    if (isDownloadReady) {
                                      statusColor = Colors.green;
                                      statusIcon = Icons.check_circle_outline_rounded;
                                      statusText = "INSTALL";
                                    } else if (isDownloading) {
                                      statusColor = Colors.blue;
                                      statusIcon = Icons.downloading_rounded;
                                      statusText = "${(progress * 100).toInt()}%";
                                    }

                                    return Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(statusIcon, color: statusColor, size: 18),
                                        const SizedBox(width: 4),
                                        Text(statusText,
                                            style: TextStyle(
                                                color: statusColor,
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.2)),
                                      ],
                                    );
                                  }(),
                                )
                              : Text(widget.currentTime,
                                  key: const ValueKey('clock'),
                                  style: theme.textTheme.titleLarge
                                      ?.copyWith(letterSpacing: 1.5)),
                        ))),
              );
            },
          ),

          Row(children: [
            GlassButton(
                icon: widget.isMusicMode
                    ? Icons.radio_rounded
                    : Icons.library_music_rounded,
                onPressed: widget.onToggleMode),
            const SizedBox(width: 12),
            if (widget.isMusicMode) ...[
              GlassButton(
                icon: Icons.download_rounded,
                onPressed: widget.onDownload,
              ),
              const SizedBox(width: 12),
            ],
            if (!widget.isMusicMode) ...[
              GlassButton(
                  icon: Icons.queue_music_rounded,
                  onPressed: () => showModalBottomSheet(
                      context: context,
                      backgroundColor: Colors.transparent,
                      isScrollControlled: true,
                      builder: (_) => const AllStationsSheet())),
              const SizedBox(width: 12),
            ],
            GlassButton(
                icon: Icons.settings_outlined,
                onPressed: () => showModalBottomSheet(
                    context: context,
                    backgroundColor: Colors.transparent,
                    isScrollControlled: true,
                    builder: (_) => const SettingsSheet()))
          ])
        ]));
  }
}


abstract class BottomSheetStyles {
  static LinearGradient glassGradient(BuildContext context) => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.4),
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.2)
          ]);

  static LinearGradient glassBorderGradient(BuildContext context) =>
      LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).primaryColor.withValues(alpha: 0.6),
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.2)
          ]);
}
