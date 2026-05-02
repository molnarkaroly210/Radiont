import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/dns_service.dart';

class ThemeProvider extends ChangeNotifier {
  final SharedPreferences prefs;
  ThemeMode _themeMode = ThemeMode.system;
  Color _selectedColor = const Color(0xFF00FFFF);
  bool _isAlwaysOn = false;
  bool _isFullScreen = false;
  bool _backgroundPlayback = false;
  bool _playButtonBlack = false;
  String _dnsProvider = DnsService.adguardDefault;

  ThemeMode get themeMode => _themeMode;
  Color get selectedColor => _selectedColor;
  bool get isAlwaysOn => _isAlwaysOn;
  bool get isFullScreen => _isFullScreen;
  bool get backgroundPlayback => _backgroundPlayback;
  bool get playButtonBlack => _playButtonBlack;
  String get dnsProvider => _dnsProvider;

  ThemeProvider(this.prefs) {
    _loadSettings();
  }

  void _loadSettings() {
    _themeMode = ThemeMode.values.firstWhere(
        (e) =>
            e.toString() ==
            'ThemeMode.${prefs.getString('themeMode') ?? 'system'}',
        orElse: () => ThemeMode.system);
    _selectedColor =
        Color(prefs.getInt('themeColor') ?? const Color(0xFF00FFFF).toARGB32());
    _isAlwaysOn = prefs.getBool('isAlwaysOn') ?? false;
    WakelockPlus.toggle(enable: _isAlwaysOn);
    _isFullScreen = prefs.getBool('isFullScreen') ?? false;
    _backgroundPlayback = prefs.getBool('backgroundPlayback') ?? false;
    _playButtonBlack = prefs.getBool('playButtonBlack') ?? false;
    _dnsProvider = prefs.getString('dnsProvider') ?? DnsService.adguardDefault;
    DnsService.setProvider(_dnsProvider);
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

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await prefs.setString('themeMode', mode.name);
    notifyListeners();
  }

  Future<void> setThemeColor(Color color) async {
    _selectedColor = color;
    await prefs.setInt('themeColor', color.toARGB32());
    notifyListeners();
  }

  Future<void> setAlwaysOn(bool value) async {
    _isAlwaysOn = value;
    WakelockPlus.toggle(enable: _isAlwaysOn);
    await prefs.setBool('isAlwaysOn', value);
    notifyListeners();
  }

  Future<void> setFullScreen(bool value) async {
    _isFullScreen = value;
    _applyFullScreen();
    await prefs.setBool('isFullScreen', value);
    notifyListeners();
  }

  Future<void> setBackgroundPlayback(bool value) async {
    _backgroundPlayback = value;
    await prefs.setBool('backgroundPlayback', value);
    notifyListeners();
  }

  Future<void> setPlayButtonBlack(bool value) async {
    _playButtonBlack = value;
    await prefs.setBool('playButtonBlack', value);
    notifyListeners();
  }

  Future<void> setDnsProvider(String dohUrl) async {
    _dnsProvider = dohUrl;
    DnsService.setProvider(dohUrl);
    await prefs.setString('dnsProvider', dohUrl);
    notifyListeners();
  }

  ThemeData getDarkTheme() => _createThemeData(Brightness.dark);
  ThemeData getLightTheme() => _createThemeData(Brightness.light);

  ThemeData _createThemeData(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = _selectedColor;
    final scaffoldBg =
        isDark ? const Color(0xFF050816) : const Color(0xFFF8F9FA);
    final surfaceColor =
        isDark ? const Color(0xFF1C1C2E).withValues(alpha: 0.5) : Colors.white;
    final onBgColor =
        isDark ? Colors.white.withValues(alpha: 0.9) : Colors.black87;
    final headlineColor = isDark ? Colors.white : Colors.black;

    final baseTheme = ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: scaffoldBg,
      primaryColor: primary,
      textTheme: GoogleFonts.poppinsTextTheme(
        TextTheme(
            headlineMedium: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                fontSize: 24,
                color: headlineColor),
            titleLarge:
                TextStyle(fontWeight: FontWeight.bold, color: headlineColor),
            titleMedium:
                TextStyle(fontWeight: FontWeight.w600, color: onBgColor),
            bodyMedium: TextStyle(
                color: onBgColor.withValues(alpha: 0.8), fontSize: 14),
            labelLarge: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent, elevation: 0, centerTitle: true),
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
            surface: surfaceColor,
            onSurface: onBgColor,
            surfaceContainerHighest:
                isDark ? const Color(0xFF333850) : const Color(0xFFE8EAF0)),
        iconTheme: IconThemeData(color: primary, size: 26),
        sliderTheme: const SliderThemeData(
            trackHeight: 4,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 18)));
  }
}
