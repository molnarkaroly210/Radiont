// lib/main.dart

import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:simple_animations/simple_animations.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:just_audio/just_audio.dart';
import 'package:volume_controller/volume_controller.dart';

import 'api_service.dart';

// =================================================================
// PROVIDEREK
// =================================================================

class ThemeProvider extends ChangeNotifier {
  final SharedPreferences prefs;
  ThemeMode _themeMode = ThemeMode.system;
  Color _selectedColor = const Color(0xFF00FFFF);
  bool _isAlwaysOn = false;
  bool _isFullScreen = false;
  bool _backgroundPlayback = false;
  bool _playButtonBlack = false;

  ThemeMode get themeMode => _themeMode;
  Color get selectedColor => _selectedColor;
  bool get isAlwaysOn => _isAlwaysOn;
  bool get isFullScreen => _isFullScreen;
  bool get backgroundPlayback => _backgroundPlayback;
  bool get playButtonBlack => _playButtonBlack;

  ThemeProvider(this.prefs) { _loadSettings(); }

  void _loadSettings() {
    _themeMode = ThemeMode.values.firstWhere((e) => e.toString() == 'ThemeMode.${prefs.getString('themeMode') ?? 'system'}', orElse: () => ThemeMode.system);
    _selectedColor = Color(prefs.getInt('themeColor') ?? const Color(0xFF00FFFF).value);
    _isAlwaysOn = prefs.getBool('isAlwaysOn') ?? false;
    WakelockPlus.toggle(enable: _isAlwaysOn);
    _isFullScreen = prefs.getBool('isFullScreen') ?? false;
    _backgroundPlayback = prefs.getBool('backgroundPlayback') ?? false;
    _playButtonBlack = prefs.getBool('playButtonBlack') ?? false;
    _applyFullScreen();
    notifyListeners();
  }

  void _applyFullScreen() {
    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async { _themeMode = mode; await prefs.setString('themeMode', mode.name); notifyListeners(); }
  Future<void> setThemeColor(Color color) async { _selectedColor = color; await prefs.setInt('themeColor', color.value); notifyListeners(); }
  Future<void> setAlwaysOn(bool value) async { _isAlwaysOn = value; WakelockPlus.toggle(enable: _isAlwaysOn); await prefs.setBool('isAlwaysOn', value); notifyListeners(); }
  Future<void> setFullScreen(bool value) async { _isFullScreen = value; _applyFullScreen(); await prefs.setBool('isFullScreen', value); notifyListeners(); }
  Future<void> setBackgroundPlayback(bool value) async { _backgroundPlayback = value; await prefs.setBool('backgroundPlayback', value); notifyListeners(); }
  Future<void> setPlayButtonBlack(bool value) async { _playButtonBlack = value; await prefs.setBool('playButtonBlack', value); notifyListeners(); }
  
  ThemeData getDarkTheme() => _createThemeData(Brightness.dark);
  ThemeData getLightTheme() => _createThemeData(Brightness.light);
  
  ThemeData _createThemeData(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = _selectedColor;
    final scaffoldBg = isDark ? const Color(0xFF050816) : const Color(0xFFF8F9FA);
    final surfaceColor = isDark ? const Color(0xFF1C1C2E).withOpacity(0.5) : Colors.white;
    final onBgColor = isDark ? Colors.white.withOpacity(0.9) : Colors.black87;
    final headlineColor = isDark ? Colors.white : Colors.black;
    
    final baseTheme = ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: scaffoldBg,
      primaryColor: primary,
      textTheme: GoogleFonts.poppinsTextTheme(
        TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1, fontSize: 24, color: headlineColor),
          titleLarge: TextStyle(fontWeight: FontWeight.bold, color: headlineColor),
          titleMedium: TextStyle(fontWeight: FontWeight.w600, color: onBgColor),
          bodyMedium: TextStyle(color: onBgColor.withOpacity(0.8), fontSize: 14),
          labelLarge: const TextStyle(fontWeight: FontWeight.bold)
        ),
      ),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true),
    );
    
    return baseTheme.copyWith(
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: isDark ? Colors.black : Colors.white,
        secondary: primary,
        onSecondary: isDark ? Colors.black : Colors.white,
        error: Colors.redAccent.shade100,
        onError: Colors.black,
        background: scaffoldBg,
        onBackground: onBgColor,
        surface: surfaceColor,
        onSurface: onBgColor,
        surfaceVariant: isDark ? const Color(0xFF333850) : const Color(0xFFE8EAF0)
      ),
      iconTheme: IconThemeData(color: primary, size: 26),
      sliderTheme: const SliderThemeData(trackHeight: 4, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7), overlayShape: RoundSliderOverlayShape(overlayRadius: 18))
    );
  }
}

class RadioProvider extends ChangeNotifier {
  final SharedPreferences prefs;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final PageController pageController = PageController(viewportFraction: 0.8);

  List<RadioStation> _stations = [];
  int _currentIndex = 0;
  bool _swipeOnlyFavorites = false;
  bool _isLoading = true;
  double _systemVolume = 0.5;

  bool get isLoading => _isLoading;
  List<RadioStation> get stations => _stations;
  List<RadioStation> get favoriteStations => _stations.where((s) => s.isFavorite).toList();
  List<RadioStation> get activeStations => _swipeOnlyFavorites ? favoriteStations : _stations;
  RadioStation get currentStation => activeStations.isEmpty ? RadioStation(id: '', name: 'Nincs állomás', streamUrl: '', imageUrl: 'assets/images/default_radio.png') : activeStations[_currentIndex];
  int get currentIndex => _currentIndex;
  bool get swipeOnlyFavorites => _swipeOnlyFavorites;
  AudioPlayer get audioPlayer => _audioPlayer;
  double get systemVolume => _systemVolume;

  RadioProvider(this.prefs) {
    _loadInitialData();
    _audioPlayer.playerStateStream.listen((state) {
      notifyListeners();
    });
    
    VolumeController().listener((volume) {
      _systemVolume = volume;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    pageController.dispose();
    VolumeController().removeListener();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    _isLoading = true;
    notifyListeners();
    _stations = await RadioBrowserApi().fetchStations();
    _loadSettings();
    _isLoading = false;
    notifyListeners();
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
    final station = _stations.firstWhere((s) => s.id == stationId, orElse: () => currentStation);
    if(station.id.isEmpty) return;
    station.isFavorite = !station.isFavorite;
    final favoriteIds = _stations.where((s) => s.isFavorite).map((s) => s.id).toList();
    await prefs.setStringList('favoriteStations', favoriteIds);
    HapticFeedback.mediumImpact();
    notifyListeners();
  }

  Future<void> setStationByIndex(int index) async {
    if (activeStations.isEmpty) return;
    _currentIndex = index;
    final stationToPlay = activeStations[index];
    
    try {
      if (stationToPlay.streamUrl.isNotEmpty) {
        await _audioPlayer.setUrl(stationToPlay.streamUrl);
        _audioPlayer.play();
      }
    } catch (e) {
      print("Lejátszási hiba: $e");
    }
    notifyListeners();
  }

  Future<void> setSwipeOnlyFavorites(bool value) async {
    final oldStation = currentStation;
    _swipeOnlyFavorites = value;
    int newIndex = activeStations.indexWhere((s) => s.id == oldStation.id);
    _currentIndex = (newIndex == -1) ? 0 : newIndex;
    if (pageController.hasClients) {
      pageController.jumpToPage(_currentIndex);
    }
    await prefs.setBool('swipeOnlyFavorites', value);
    notifyListeners();
  }

  void nextStation() {
    if (activeStations.length < 2) return;
    int nextIndex = (_currentIndex + 1) % activeStations.length;
    pageController.animateToPage(nextIndex, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
  }

  void previousStation() {
    if (activeStations.length < 2) return;
    int prevIndex = (_currentIndex - 1 + activeStations.length) % activeStations.length;
    pageController.animateToPage(prevIndex, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
  }

  void togglePlayPause() {
    if (_audioPlayer.playing) {
      _audioPlayer.pause();
    } else {
      if (_audioPlayer.processingState == ProcessingState.ready) {
        _audioPlayer.play();
      } else if(_audioPlayer.processingState == ProcessingState.idle || _audioPlayer.processingState == ProcessingState.completed){
        setStationByIndex(_currentIndex);
      }
    }
  }
  
  void setSystemVolume(double volume) {
    _systemVolume = volume;
    VolumeController().setVolume(volume);
    notifyListeners();
  }
}

// =================================================================
// ALKALMAZÁS BELÉPÉSI PONTJA
// =================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider(prefs)),
        ChangeNotifierProvider(create: (_) => RadioProvider(prefs)),
      ],
      child: const RadiontApp(),
    ),
  );
}

class RadiontApp extends StatelessWidget {
  const RadiontApp({super.key});
  
  @override
  Widget build(BuildContext context) {
    context.watch<ThemeProvider>().isFullScreen;
    return MaterialApp(
      title: 'Radiont',
      theme: context.read<ThemeProvider>().getLightTheme(),
      darkTheme: context.read<ThemeProvider>().getDarkTheme(),
      themeMode: context.watch<ThemeProvider>().themeMode,
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

  @override
  void initState() {
    super.initState();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) => _updateTime());
  }

  void _updateTime() { if (mounted) setState(() => _currentTime = DateFormat('HH:mm').format(DateTime.now())); }
  
  @override
  void dispose() { 
    _timer?.cancel(); 
    super.dispose(); 
  }
  
  void _showFavoritesSheet() => showModalBottomSheet(
    context: context, 
    backgroundColor: Colors.transparent, 
    isScrollControlled: true, 
    builder: (_) => const FavoritesSheet()
  );

  @override
  Widget build(BuildContext context) {
    final radioProvider = context.watch<RadioProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stationsToDisplay = radioProvider.activeStations;
    
    return Scaffold(
      body: Stack(
        children: [
          const AnimatedBackground(),
          if (!radioProvider.isLoading && radioProvider.stations.isNotEmpty)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 800), 
              transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child), 
              child: Container(
                key: ValueKey<String>(radioProvider.currentStation.imageUrl), 
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: NetworkImage(radioProvider.currentStation.imageUrl), 
                    fit: BoxFit.cover
                  )
                ), 
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), 
                  child: Container(
                    color: (isDark ? Colors.black : Colors.white).withOpacity(isDark ? 0.6 : 0.2)
                  )
                )
              )
            ),
          
          SafeArea(
            bottom: !themeProvider.isFullScreen,
            top: !themeProvider.isFullScreen,
            child: radioProvider.isLoading
                ? Center(child: CircularProgressIndicator(color: themeProvider.selectedColor))
                : Column(
                    children: [
                      if (themeProvider.isFullScreen) const SizedBox(height: 10),
                      TopBar(currentTime: _currentTime),
                      Expanded(
                        child: stationsToDisplay.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 40.0), 
                                  child: Text(
                                    "Nincsenek kedvenceid.\nKapcsold ki a \"Csak a kedvencek lapozása\" opciót a beállításokban, vagy adj hozzá állomásokat a szív ikonnal.", 
                                    textAlign: TextAlign.center, 
                                    style: Theme.of(context).textTheme.titleMedium
                                  )
                                )
                              )
                            : PageView.builder(
                                controller: radioProvider.pageController,
                                itemCount: stationsToDisplay.length,
                                onPageChanged: (index) {
                                  radioProvider.setStationByIndex(index);
                                },
                                itemBuilder: (context, index) {
                                  final station = stationsToDisplay[index];
                                  return AnimatedBuilder(
                                    animation: radioProvider.pageController,
                                    builder: (context, child) {
                                      double value = 1.0;
                                      if (radioProvider.pageController.position.haveDimensions) { 
                                        value = (radioProvider.pageController.page ?? 0.0) - index; 
                                        value = (1 - (value.abs() * 0.4)).clamp(0.0, 1.0); 
                                      }
                                      return Center(
                                        child: Transform.scale(
                                          scale: value, 
                                          child: Opacity(
                                            opacity: value * value, 
                                            child: child
                                          )
                                        )
                                      );
                                    },
                                    child: RadioCard(station: station),
                                  );
                                },
                              ),
                      ),
                      GestureDetector(
                        onVerticalDragEnd: (details) { 
                          if (details.primaryVelocity != null && details.primaryVelocity! < -500) _showFavoritesSheet(); 
                        }, 
                        child: Column(
                          mainAxisSize: MainAxisSize.min, 
                          children: [
                            Container(
                              width: 40, 
                              height: 5, 
                              margin: const EdgeInsets.only(bottom: 10), 
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3), 
                                borderRadius: BorderRadius.circular(10)
                              )
                            ), 
                            const PlayerControls()
                          ]
                        )
                      ), 
                      const SizedBox(height: 16),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// =================================================================
// EGYÉB WIDGETEK
// =================================================================

class RadioCard extends StatelessWidget {
  final RadioStation station;
  const RadioCard({super.key, required this.station});
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 1, 
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 20), 
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(40), 
          image: DecorationImage(
            image: NetworkImage(station.imageUrl), 
            fit: BoxFit.cover
          ), 
          boxShadow: [
            BoxShadow(
              color: theme.primaryColor.withOpacity(0.6), 
              blurRadius: 30, 
              spreadRadius: 0, 
              offset: const Offset(0, 10)
            ), 
            BoxShadow(
              color: Colors.black.withOpacity(0.3), 
              blurRadius: 25, 
              spreadRadius: -5, 
              offset: const Offset(0, 15)
            )
          ]
        )
      )
    );
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
      final buttonColor = themeProvider.playButtonBlack ? Colors.black : Colors.white;
      
      if (processingState == ProcessingState.loading || processingState == ProcessingState.buffering) {
        return Container(
          width: 70, 
          height: 70, 
          padding: const EdgeInsets.all(15), 
          decoration: BoxDecoration(
            color: theme.primaryColor, 
            shape: BoxShape.circle
          ), 
          child: CircularProgressIndicator(
            color: buttonColor, 
            strokeWidth: 3
          )
        );
      } else {
        return GestureDetector(
          onTap: radioProvider.togglePlayPause, 
          child: Container(
            width: 70, 
            height: 70, 
            decoration: BoxDecoration(
              color: theme.primaryColor, 
              shape: BoxShape.circle, 
              boxShadow: [
                BoxShadow(
                  color: theme.primaryColor.withOpacity(0.7), 
                  blurRadius: 20, 
                  spreadRadius: 2
                )
              ]
            ), 
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, 
              size: 45, 
              color: buttonColor
            )
          )
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
      linearGradient: LinearGradient(
        colors: [
          theme.colorScheme.surface.withOpacity(0.15), 
          theme.colorScheme.surface.withOpacity(0.05)
        ], 
        begin: Alignment.topLeft, 
        end: Alignment.bottomRight
      ), 
      borderGradient: LinearGradient(
        colors: [
          theme.primaryColor.withOpacity(0.5), 
          theme.colorScheme.surface.withOpacity(0.1)
        ], 
        begin: Alignment.topLeft, 
        end: Alignment.bottomRight
      ), 
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 25.0, vertical: 20.0), 
        child: radioProvider.activeStations.isEmpty 
          ? Center(child: Text("Nincs lejátszható állomás", style: theme.textTheme.titleMedium))
          : Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween, 
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center, 
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, 
                        children: [
                          Text(
                            station.name, 
                            style: theme.textTheme.headlineMedium, 
                            maxLines: 1, 
                            overflow: TextOverflow.ellipsis
                          ),
                          const SizedBox(height: 5),
                          Text(
                            station.nowPlaying, 
                            style: theme.textTheme.bodyMedium, 
                            maxLines: 1, 
                            overflow: TextOverflow.ellipsis
                          )
                        ]
                      )
                    ),
                    const SizedBox(width: 15),
                    IconButton(
                      padding: EdgeInsets.zero, 
                      icon: Icon(
                        station.isFavorite ? Icons.favorite : Icons.favorite_border, 
                        color: station.isFavorite ? const Color(0xFFE91E63) : theme.primaryColor, 
                        size: 30
                      ), 
                      onPressed: () => radioProvider.toggleFavorite(station.id)
                    )
                  ]
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround, 
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous_rounded), 
                      onPressed: radioProvider.previousStation, 
                      iconSize: 38, 
                      color: theme.iconTheme.color?.withOpacity(0.8)
                    ),
                    playPauseButton(),
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded), 
                      onPressed: radioProvider.nextStation, 
                      iconSize: 38, 
                      color: theme.iconTheme.color?.withOpacity(0.8)
                    )
                  ]
                ),
                Row(
                  children: [
                    Icon(
                      Icons.volume_mute_rounded, 
                      size: 22, 
                      color: theme.iconTheme.color?.withOpacity(0.6)
                    ),
                    Expanded(
                      child: Slider(
                        value: radioProvider.systemVolume,
                        onChanged: radioProvider.setSystemVolume,
                        activeColor: theme.primaryColor,
                        inactiveColor: theme.colorScheme.surfaceVariant
                      )
                    ),
                    Icon(
                      Icons.volume_up_rounded, 
                      size: 22, 
                      color: theme.iconTheme.color?.withOpacity(0.6)
                    )
                  ]
                )
              ]
            )
      )
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
    final radioProvider = context.read<RadioProvider>();
    final theme = Theme.of(context);
    
    return GlassmorphicContainer(
      width: double.infinity, 
      height: MediaQuery.of(context).size.height * 0.8, 
      borderRadius: 30, 
      blur: 20, 
      border: 1, 
      linearGradient: BottomSheetStyles.glassGradient(context), 
      borderGradient: BottomSheetStyles.glassBorderGradient(context), 
      child: Column(
        children: [
          Container(
            width: 40, 
            height: 5, 
            margin: const EdgeInsets.symmetric(vertical: 15), 
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.3), 
              borderRadius: BorderRadius.circular(10)
            )
          ),
          Text("Összes Állomás", style: theme.textTheme.titleLarge),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 15.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Keresés...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none
                ),
                filled: true,
                fillColor: theme.colorScheme.surface.withOpacity(0.2),
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
                final bool isCurrentlyPlaying = radioProvider.currentStation.id == station.id && radioProvider.audioPlayer.playing; 
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), 
                  leading: CircleAvatar(
                    radius: 25, 
                    backgroundImage: NetworkImage(station.imageUrl), 
                    onBackgroundImageError: (e,s) => {}, 
                    child: Image.asset('assets/images/default_radio.png')
                  ), 
                  title: Text(station.name, style: theme.textTheme.titleMedium), 
                  subtitle: Text(
                    station.nowPlaying, 
                    style: theme.textTheme.bodyMedium, 
                    maxLines: 1, 
                    overflow: TextOverflow.ellipsis
                  ), 
                  trailing: isCurrentlyPlaying 
                    ? Icon(Icons.bar_chart_rounded, color: theme.primaryColor) 
                    : IconButton(
                        icon: Icon(
                          Icons.play_circle_outline_rounded, 
                          color: theme.primaryColor.withOpacity(0.7), 
                          size: 30
                        ), 
                        onPressed: () async { 
                          await context.read<RadioProvider>().setSwipeOnlyFavorites(false); 
                          final newIndex = radioProvider.stations.indexWhere((s) => s.id == station.id); 
                          if (newIndex != -1) { 
                            radioProvider.pageController.jumpToPage(newIndex); 
                            radioProvider.setStationByIndex(newIndex); 
                          } 
                          Navigator.pop(context); 
                        }
                      ), 
                  onTap: () async { 
                    await context.read<RadioProvider>().setSwipeOnlyFavorites(false); 
                    final newIndex = radioProvider.stations.indexWhere((s) => s.id == station.id); 
                    if (newIndex != -1) { 
                      radioProvider.pageController.jumpToPage(newIndex); 
                      radioProvider.setStationByIndex(newIndex); 
                    } 
                    Navigator.pop(context); 
                  }
                ); 
              }
            )
          )
        ]
      )
    );
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
      child: Column(
        children: [
          Container(
            width: 40, 
            height: 5, 
            margin: const EdgeInsets.symmetric(vertical: 15), 
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.3), 
              borderRadius: BorderRadius.circular(10)
            )
          ),
          Text("Kedvencek", style: theme.textTheme.titleLarge),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 15.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Keresés...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none
                ),
                filled: true,
                fillColor: theme.colorScheme.surface.withOpacity(0.2),
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
                      style: theme.textTheme.bodyMedium
                    )
                  )
                ) 
              : ListView.builder(
                  padding: const EdgeInsets.all(12), 
                  itemCount: favorites.length, 
                  itemBuilder: (context, index) { 
                    final station = favorites[index]; 
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), 
                      leading: CircleAvatar(
                        radius: 25, 
                        backgroundImage: NetworkImage(station.imageUrl)
                      ), 
                      title: Text(station.name, style: theme.textTheme.titleMedium), 
                      subtitle: Text(
                        station.nowPlaying, 
                        style: theme.textTheme.bodyMedium, 
                        maxLines: 1, 
                        overflow: TextOverflow.ellipsis
                      ), 
                      trailing: IconButton(
                        icon: Icon(
                          Icons.play_circle_fill_rounded, 
                          color: theme.primaryColor, 
                          size: 30
                        ), 
                        onPressed: () async { 
                          await context.read<RadioProvider>().setSwipeOnlyFavorites(true); 
                          final newIndex = radioProvider.favoriteStations.indexWhere((s) => s.id == station.id); 
                          if (newIndex != -1) { 
                            radioProvider.pageController.jumpToPage(newIndex); 
                            radioProvider.setStationByIndex(newIndex); 
                          } 
                          Navigator.pop(context); 
                        }
                      )
                    ); 
                  }
                )
          )
        ]
      )
    );
  }
}

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});
  
  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final radioProvider = context.watch<RadioProvider>();
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
        padding: const EdgeInsets.symmetric(horizontal: 15.0, vertical: 20.0), 
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, 
            children: [
              Center(child: Text("Beállítások", style: theme.textTheme.titleLarge)),
              const SizedBox(height: 20),
              Padding(padding: const EdgeInsets.only(left: 10.0), child: Text("Megjelenés", style: theme.textTheme.titleMedium)),
              const SizedBox(height: 10),
              SegmentedButton<ThemeMode>(
                segments: const <ButtonSegment<ThemeMode>>[
                  ButtonSegment<ThemeMode>(value: ThemeMode.light, label: Text('Világos'), icon: Icon(Icons.wb_sunny_outlined)),
                  ButtonSegment<ThemeMode>(value: ThemeMode.dark, label: Text('Sötét'), icon: Icon(Icons.nightlight_outlined)),
                  ButtonSegment<ThemeMode>(value: ThemeMode.system, label: Text('Rendszer'), icon: Icon(Icons.brightness_auto_outlined))
                ], 
                selected: {themeProvider.themeMode}, 
                onSelectionChanged: (s) => themeProvider.setThemeMode(s.first), 
                style: _segmentedButtonStyle(context)
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                title: Text("Teljes képernyő", style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.normal)), 
                subtitle: Text("Elrejti a rendszer állapotsávját", style: theme.textTheme.bodyMedium), 
                value: themeProvider.isFullScreen, 
                onChanged: themeProvider.setFullScreen, 
                activeColor: theme.primaryColor, 
                contentPadding: const EdgeInsets.symmetric(horizontal: 10)
              ),
              const Divider(height: 25, thickness: 0.5),
              Padding(padding: const EdgeInsets.only(left: 10.0), child: Text("Lejátszás", style: theme.textTheme.titleMedium)),
              SwitchListTile(
                title: Text("Képernyő ébren tartása", style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.normal)), 
                subtitle: Text("Megakadályozza a képernyő kikapcsolását", style: theme.textTheme.bodyMedium), 
                value: themeProvider.isAlwaysOn, 
                onChanged: themeProvider.setAlwaysOn, 
                activeColor: theme.primaryColor, 
                contentPadding: const EdgeInsets.symmetric(horizontal: 10)
              ),
              SwitchListTile(
                title: Text("Csak a kedvencek lapozása", style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.normal)), 
                subtitle: Text("A főképernyőn csak a kedvencek jelennek meg", style: theme.textTheme.bodyMedium), 
                value: radioProvider.swipeOnlyFavorites, 
                onChanged: radioProvider.setSwipeOnlyFavorites, 
                activeColor: theme.primaryColor, 
                contentPadding: const EdgeInsets.symmetric(horizontal: 10)
              ),
              const Divider(height: 25, thickness: 0.5),
              Padding(padding: const EdgeInsets.only(left: 10.0), child: Text("Neonszín", style: theme.textTheme.titleMedium)),
              const SizedBox(height: 20),
              Column(
                children: [
                  Container(
                    height: 50,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(25),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFFff0000), // Red
                          Color(0xFFFFFF00), // Yellow
                          Color(0xFF00FF00), // Green
                          Color(0xFF00FFFF), // Cyan
                          Color(0xFF0000FF), // Blue
                          Color(0xFFFF00FF), // Magenta
                          Color(0xFFff0000), // Red
                        ],
                        stops: [0.0, 0.16, 0.33, 0.5, 0.66, 0.83, 1.0],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
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
                      final color = HSVColor.fromAHSV(1.0, value, 1.0, 1.0).toColor();
                      themeProvider.setThemeColor(color);
                    },
                    activeColor: themeProvider.selectedColor,
                    inactiveColor: theme.colorScheme.surfaceVariant,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: themeProvider.selectedColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: themeProvider.selectedColor.withOpacity(0.7),
                          blurRadius: 15,
                          spreadRadius: 3
                        )
                      ]
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                title: Text("Lejátszás gomb fekete", style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.normal)), 
                subtitle: Text("Alapértelmezetten fehér", style: theme.textTheme.bodyMedium), 
                value: themeProvider.playButtonBlack, 
                onChanged: themeProvider.setPlayButtonBlack, 
                activeColor: theme.primaryColor, 
                contentPadding: const EdgeInsets.symmetric(horizontal: 10)
              ),
            ]
          )
        )
      )
    );
  }
  
  ButtonStyle _segmentedButtonStyle(BuildContext context) { 
    final theme = Theme.of(context); 
    return ButtonStyle(
      backgroundColor: MaterialStateProperty.resolveWith<Color?>((states) { 
        if (states.contains(MaterialState.selected)) return theme.primaryColor; 
        return theme.colorScheme.surfaceVariant.withOpacity(0.5); 
      }), 
      foregroundColor: MaterialStateProperty.resolveWith<Color?>((states) { 
        if (states.contains(MaterialState.selected)) return theme.colorScheme.onPrimary; 
        return theme.colorScheme.onSurface; 
      }), 
      shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), 
      padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 10, vertical: 8))
    ); 
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
  @override Widget build(BuildContext context) { 
    final themeProvider = context.watch<ThemeProvider>(); 
    final primaryColor = themeProvider.selectedColor; 
    return LoopAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0), 
      duration: const Duration(seconds: 40), 
      builder: (context, value, child) => CustomPaint(
        painter: BackgroundPainter(value, primaryColor), 
        child: Container()
      )
    ); 
  } 
}

class BackgroundPainter extends CustomPainter { 
  final double animationValue; 
  final Color primaryColor; 
  BackgroundPainter(this.animationValue, this.primaryColor); 
  @override void paint(Canvas canvas, Size size) { 
    final color1 = primaryColor; 
    final color2 = HSLColor.fromColor(primaryColor).withLightness(0.7).toColor(); 
    const double blurAmount = 150.0; 
    final paint1 = Paint()..color = color1.withOpacity(0.4)..maskFilter = const MaskFilter.blur(BlurStyle.normal, blurAmount); 
    final paint2 = Paint()..color = color2.withOpacity(0.4)..maskFilter = const MaskFilter.blur(BlurStyle.normal, blurAmount); 
    final paint3 = Paint()..color = color1.withOpacity(0.3)..maskFilter = const MaskFilter.blur(BlurStyle.normal, blurAmount); 
    final progress = animationValue * 2 * pi; 
    final position1 = Offset(size.width * 0.5 + sin(progress) * size.width * 0.4, size.height * 0.5 + cos(progress) * size.height * 0.4); 
    final position2 = Offset(size.width * 0.5 + cos(progress * 0.8) * size.width * 0.5, size.height * 0.2 + sin(progress * 0.8) * size.height * 0.3); 
    final position3 = Offset(size.width * 0.2 + sin(progress * 1.2) * size.width * 0.3, size.height * 0.8 + cos(progress * 1.2) * size.height * 0.4); 
    canvas.drawCircle(position1, size.width * 0.5, paint1); 
    canvas.drawCircle(position2, size.width * 0.4, paint2); 
    canvas.drawCircle(position3, size.width * 0.3, paint3); 
  } 
  
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => true; 
}

class GlassButton extends StatelessWidget { 
  final VoidCallback onPressed; 
  final IconData icon; 
  const GlassButton({super.key, required this.onPressed, required this.icon}); 
  @override Widget build(BuildContext context) { 
    final theme = Theme.of(context); 
    return GlassmorphicContainer(
      width: 50, 
      height: 50, 
      borderRadius: 25, 
      blur: 20, 
      alignment: Alignment.center, 
      border: 1, 
      linearGradient: LinearGradient(
        colors: [
          theme.colorScheme.surface.withOpacity(0.2), 
          theme.colorScheme.surface.withOpacity(0.1)
        ], 
        begin: Alignment.topLeft, 
        end: Alignment.bottomRight
      ), 
      borderGradient: LinearGradient(
        colors: [
          theme.primaryColor.withOpacity(0.6), 
          theme.colorScheme.surface.withOpacity(0.2)
        ], 
        begin: Alignment.topLeft, 
        end: Alignment.bottomRight
      ), 
      child: IconButton(
        icon: Icon(icon, size: 24, color: theme.iconTheme.color), 
        onPressed: onPressed
      )
    ); 
  } 
}

class TopBar extends StatelessWidget { 
  final String currentTime; 
  const TopBar({super.key, required this.currentTime}); 
  @override Widget build(BuildContext context) { 
    final theme = Theme.of(context); 
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15), 
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween, 
        children: [
          GlassmorphicContainer(
            width: 110, 
            height: 45, 
            borderRadius: 25, 
            blur: 20, 
            alignment: Alignment.center, 
            border: 1, 
            linearGradient: LinearGradient(
              colors: [
                theme.colorScheme.surface.withOpacity(0.2), 
                theme.colorScheme.surface.withOpacity(0.1)
              ], 
              begin: Alignment.topLeft, 
              end: Alignment.bottomRight
            ), 
            borderGradient: LinearGradient(
              colors: [
                theme.primaryColor.withOpacity(0.6), 
                theme.colorScheme.surface.withOpacity(0.2)
              ], 
              begin: Alignment.topLeft, 
              end: Alignment.bottomRight
            ), 
            child: Text(
              currentTime, 
              style: theme.textTheme.titleLarge?.copyWith(letterSpacing: 1.5)
            )
          ), 
          Row(
            children: [
              GlassButton(
                icon: Icons.queue_music_rounded, 
                onPressed: () => showModalBottomSheet(
                  context: context, 
                  backgroundColor: Colors.transparent, 
                  isScrollControlled: true, 
                  builder: (_) => const AllStationsSheet()
                )
              ), 
              const SizedBox(width: 12), 
              GlassButton(
                icon: Icons.settings_outlined, 
                onPressed: () => showModalBottomSheet(
                  context: context, 
                  backgroundColor: Colors.transparent, 
                  isScrollControlled: true, 
                  builder: (_) => const SettingsSheet()
                )
              )
            ]
          )
        ]
      )
    ); 
  } 
}

abstract class BottomSheetStyles { 
  static LinearGradient glassGradient(BuildContext context) => LinearGradient(
    begin: Alignment.topLeft, 
    end: Alignment.bottomRight, 
    colors: [
      Theme.of(context).colorScheme.surface.withOpacity(0.4), 
      Theme.of(context).colorScheme.surface.withOpacity(0.2)
    ]
  ); 
  
  static LinearGradient glassBorderGradient(BuildContext context) => LinearGradient(
    begin: Alignment.topLeft, 
    end: Alignment.bottomRight, 
    colors: [
      Theme.of(context).primaryColor.withOpacity(0.6), 
      Theme.of(context).colorScheme.surface.withOpacity(0.2)
    ]
  ); 
}