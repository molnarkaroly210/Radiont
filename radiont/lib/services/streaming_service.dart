import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/foundation.dart';
import '../providers/music_provider.dart';
import '../providers/theme_provider.dart';

class StreamingService {
  static final StreamingService _instance = StreamingService._internal();
  factory StreamingService() => _instance;
  StreamingService._internal();

  HttpServer? _server;
  String? _ip;
  final int port = 8080;
  bool _isRunning = false;
  bool _pinEnabled = false;
  String? _pin;
  bool _guestModeEnabled = false;

  bool get isRunning => _isRunning;
  String? get url => _ip != null ? 'http://$_ip:$port' : null;

  Future<void> startServer(MusicProvider musicProvider, dynamic radioProvider, ThemeProvider themeProvider, {bool pinEnabled = false, String? pin, bool guestModeEnabled = false}) async {
    if (_isRunning) return;
    _pinEnabled = pinEnabled;
    _pin = pin;
    _guestModeEnabled = guestModeEnabled;

    try {
      final info = NetworkInfo();
      _ip = await info.getWifiIP();
      
      var handler = const Pipeline()
          .addMiddleware(logRequests())
          .addHandler((request) => _handleRequest(request, musicProvider, radioProvider, themeProvider));

      _server = await io.serve(handler, InternetAddress.anyIPv4, port);
      _isRunning = true;
      debugPrint('Szerver elindítva: http://$_ip:$port');
    } catch (e) {
      debugPrint('Szerver hiba: $e');
      _isRunning = false;
      rethrow;
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _ip = null;
    _isRunning = false;
  }

  Future<Response> _handleRequest(Request request, MusicProvider musicProvider, dynamic radioProvider, ThemeProvider themeProvider) async {
    final path = request.url.path;
    final bool isMusicMode = musicProvider.isMusicModeActive;

    if (path == '' || path == 'index.html') {
      return Response.ok(_getHtmlContent(), headers: {'Content-Type': 'text/html; charset=utf-8'});
    }

    // PIN ellenőrzés az API hívásokhoz
    bool isAuthenticated = true;
    if (_pinEnabled && _pin != null) {
      final queryPin = request.url.queryParameters['pin'];
      if (queryPin != _pin) {
        isAuthenticated = false;
        
        // Ha vendég mód engedélyezve van, az olvasási műveletek mehetnek (kivéve remote vezérlés)
        bool isReadOperation = path == 'status' || path == 'songs' || path == 'stations' || path.startsWith('stream/');
        
        if (!(_guestModeEnabled && isReadOperation)) {
          if (path == 'status') {
            return Response.ok(jsonEncode({
              'isReady': true, 
              'authRequired': true, 
              'guestModeEnabled': _guestModeEnabled
            }), headers: {'Content-Type': 'application/json'});
          }
          return Response.forbidden('Érvénytelen PIN kód.');
        }
      }
    }

    if (path == 'status') {
      Map<String, dynamic> status = {
        'isReady': true, 
        'authRequired': !isAuthenticated,
        'guestModeEnabled': _guestModeEnabled,
        'isGuest': !isAuthenticated,
        'isMusicMode': isMusicMode,
        'isLoading': isMusicMode ? musicProvider.isLoading : radioProvider.isLoading,
        'volume': isMusicMode ? musicProvider.systemVolume : radioProvider.systemVolume,
        'isWebDownloadEnabled': musicProvider.isWebRemoteDownloadEnabled,
        'lastLibraryUpdate': musicProvider.lastLibraryUpdate,
        'themeColor': '#${themeProvider.selectedColor.value.toRadixString(16).padLeft(8, '0').substring(2)}',
      };

      if (isMusicMode) {
        final currentSong = musicProvider.currentSong;
        status['position'] = musicProvider.audioPlayer.position.inMilliseconds;
        status['duration'] = musicProvider.audioPlayer.duration?.inMilliseconds ?? 0;
        status['nowPlaying'] = currentSong != null ? {
          'id': currentSong.id,
          'title': musicProvider.getSongTitle(currentSong),
          'artist': musicProvider.getSongArtist(currentSong),
          'isPlaying': musicProvider.audioPlayer.playing,
        } : null;
      } else {
        final currentStation = radioProvider.currentStation;
        status['nowPlaying'] = {
          'id': 'radio',
          'title': currentStation.name,
          'artist': currentStation.nowPlaying,
          'isPlaying': radioProvider.audioPlayer.playing,
        };
        status['position'] = 0;
        status['duration'] = 0;
      }
      
      status['serverTimestamp'] = DateTime.now().millisecondsSinceEpoch;
      status['isPlaying'] = isMusicMode 
          ? musicProvider.audioPlayer.playing 
          : radioProvider.audioPlayer.playing;

      return Response.ok(jsonEncode(status), headers: {'Content-Type': 'application/json'});
    }

    if (path == 'songs' && isMusicMode) {
      final songs = musicProvider.songs.map((s) => {
        'id': s.id,
        'title': musicProvider.getSongTitle(s),
        'artist': musicProvider.getSongArtist(s),
      }).toList();
      return Response.ok(jsonEncode(songs), headers: {'Content-Type': 'application/json'});
    }

    if (path == 'stations' && !isMusicMode) {
      final stations = radioProvider.stations.map((s) => {
        'id': s.id,
        'name': s.name,
        'nowPlaying': s.nowPlaying,
        'url': s.streamUrl,
      }).toList();
      return Response.ok(jsonEncode(stations), headers: {'Content-Type': 'application/json'});
    }

    if (path.startsWith('stream/')) {
      final idStr = path.replaceFirst('stream/', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        final song = musicProvider.songs.firstWhere((s) => s.id == id);
        final file = File(song.data);
        if (await file.exists()) {
          return Response.ok(file.openRead(), headers: {
            'Content-Type': 'audio/mpeg',
            'Accept-Ranges': 'bytes',
          });
        }
      }
    }

    // Remote vezérlés
    if (path.startsWith('remote/')) {
      final action = path.replaceFirst('remote/', '');
      
      if (action.startsWith('play/radio/')) {
        final stationId = action.replaceFirst('play/radio/', '');
        int idx = radioProvider.stations.indexWhere((s) => s.id == stationId);
        if (idx != -1) radioProvider.setStationByIndex(idx, play: true);
      } else if (action.startsWith('play/')) {
        final id = int.tryParse(action.replaceFirst('play/', ''));
        if (id != null) {
          int idx = musicProvider.displayedSongs.indexWhere((s) => s.id == id);
          if (idx != -1) musicProvider.playSong(idx);
        }
      } else if (action == 'toggle') {
        isMusicMode ? musicProvider.togglePlayPause() : radioProvider.togglePlayPause();
      } else if (action == 'next') {
        isMusicMode ? musicProvider.nextSong() : radioProvider.nextStation();
      } else if (action == 'prev') {
        isMusicMode ? musicProvider.previousSong() : radioProvider.previousStation();
      } else if (action.startsWith('volume/')) {
        final vol = double.tryParse(action.replaceFirst('volume/', ''));
        if (vol != null) {
          isMusicMode ? musicProvider.setSystemVolume(vol) : radioProvider.setSystemVolume(vol);
        }
      } else if (action.startsWith('seek/')) {
        final pos = int.tryParse(action.replaceFirst('seek/', ''));
        if (pos != null && isMusicMode) {
          musicProvider.audioPlayer.seek(Duration(milliseconds: pos));
        }
      } else if (action.startsWith('mode/')) {
        final mode = action.replaceFirst('mode/', '');
        musicProvider.setMusicMode(mode == 'music', radioProvider);
      } else if (action.startsWith('yt-download/')) {
        final encodedUrl = action.replaceFirst('yt-download/', '');
        final url = Uri.decodeComponent(encodedUrl);
        musicProvider.downloadFromWebRemote(url);
      }

      return Response.ok(jsonEncode({'success': true}), headers: {'Content-Type': 'application/json'});
    }

    return Response.notFound('Nem található');
  }

  String _getHtmlContent() {
    return r'''
<!DOCTYPE html>
<html lang="hu">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Radiont Remote Player</title>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;700&family=Orbitron:wght@400;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --accent-color: #00e5ff;
            --bg: #05080a;
            --card: rgba(20, 30, 36, 0.7);
            --text: #ffffff;
            --text-dim: rgba(255, 255, 255, 0.6);
            --glass-border: rgba(255, 255, 255, 0.1);
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            -webkit-tap-highlight-color: transparent;
        }

        body {
            font-family: 'Outfit', sans-serif;
            background-color: var(--bg);
            background-image: 
                radial-gradient(circle at 0% 0%, color-mix(in srgb, var(--accent-color), transparent 95%) 0%, transparent 50%),
                radial-gradient(circle at 100% 100%, color-mix(in srgb, var(--accent-color), transparent 95%) 0%, transparent 50%);
            background-attachment: fixed;
            color: var(--text);
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            padding: 70px 20px 40px;
        }

        .container {
            width: 100%;
            max-width: 600px;
            animation: fadeIn 0.8s ease-out;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        h1 {
            font-family: 'Orbitron', sans-serif;
            font-size: 2rem;
            text-align: center;
            color: var(--accent-color);
            text-transform: uppercase;
            letter-spacing: 6px;
            margin-bottom: 40px;
            text-shadow: 0 0 20px color-mix(in srgb, var(--accent-color), transparent 50%);
        }

        /* Glass Card Style */
        .glass-card {
            background: var(--card);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--glass-border);
            border-radius: 24px;
            padding: 24px;
            margin-bottom: 24px;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4);
            transition: transform 0.3s ease, border-color 0.3s ease;
        }

        .mode-switcher {
            position: relative;
            display: flex;
            background: rgba(255, 255, 255, 0.03);
            border-radius: 20px;
            padding: 5px;
            margin-bottom: 30px;
            border: 1px solid var(--glass-border);
            overflow: hidden;
        }

        .mode-slider {
            position: absolute;
            top: 5px;
            left: 5px;
            width: calc(50% - 5px);
            height: calc(100% - 10px);
            background: var(--accent-color);
            border-radius: 16px;
            transition: transform 0.5s cubic-bezier(0.19, 1, 0.22, 1);
            box-shadow: 0 0 20px color-mix(in srgb, var(--accent-color), transparent 50%);
            z-index: 1;
        }

        .mode-btn {
            position: relative;
            flex: 1;
            padding: 15px;
            border: none;
            background: transparent;
            color: var(--text-dim);
            font-family: 'Orbitron', sans-serif;
            font-size: 0.85rem;
            font-weight: 700;
            cursor: pointer;
            z-index: 2;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 12px;
            transition: color 0.3s ease;
            letter-spacing: 1px;
        }

        .mode-btn.active {
            color: #000;
        }

        .mode-btn svg {
            width: 22px;
            height: 22px;
            transition: transform 0.3s ease;
        }

        .mode-btn:hover:not(.active) {
            color: #fff;
        }

        .mode-btn:hover svg {
            transform: scale(1.1);
        }

        .player-main {
            text-align: center;
        }

        #phone-now-playing {
            display: flex;
            flex-direction: column;
            gap: 4px;
            margin-bottom: 24px;
        }

        .song-title-main {
            font-size: 1.4rem;
            font-weight: 700;
            background: linear-gradient(to bottom, #fff, #ccc);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .song-artist-main {
            font-size: 1rem;
            color: var(--accent-color);
            opacity: 0.8;
            font-weight: 500;
        }

        /* Custom Sliders */
        input[type="range"] {
            -webkit-appearance: none;
            width: 100%;
            background: transparent;
            cursor: pointer;
        }

        input[type="range"]::-webkit-slider-runnable-track {
            background: rgba(255, 255, 255, 0.1);
            height: 6px;
            border-radius: 3px;
        }

        input[type="range"]::-webkit-slider-thumb {
            -webkit-appearance: none;
            height: 18px;
            width: 18px;
            background: #fff;
            border-radius: 50%;
            margin-top: -6px;
            box-shadow: 0 0 15px var(--accent-color);
            border: 3px solid var(--bg);
            transition: transform 0.2s ease;
        }

        input[type="range"]:active::-webkit-slider-thumb {
            transform: scale(1.3);
        }

        .controls-row {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 30px;
            margin: 20px 0;
        }

        .ctrl-btn {
            background: transparent;
            border: none;
            color: #fff;
            font-size: 1.8rem;
            cursor: pointer;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .ctrl-btn:hover {
            color: var(--accent-color);
            transform: scale(1.1);
        }

        .ctrl-btn:active {
            transform: scale(0.9);
        }

        .play-pause-btn {
            width: 70px;
            height: 70px;
            background: var(--accent-color);
            border-radius: 50%;
            color: #000;
            font-size: 1.5rem;
            box-shadow: 0 0 25px color-mix(in srgb, var(--accent-color), transparent 40%);
        }

        .play-pause-btn:hover {
            transform: scale(1.05);
            background: #fff;
            color: #000;
        }

        /* Search & List */
        .search-box {
            position: relative;
            margin-bottom: 24px;
        }

        .search-input {
            width: 100%;
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid var(--glass-border);
            padding: 16px 20px 16px 50px;
            border-radius: 20px;
            color: #fff;
            font-family: inherit;
            font-size: 1rem;
            outline: none;
            transition: all 0.3s ease;
        }

        .search-input:focus {
            background: rgba(255, 255, 255, 0.08);
            border-color: var(--accent-color);
            box-shadow: 0 0 20px rgba(0, 229, 255, 0.1);
        }

        .search-icon-abs {
            position: absolute;
            left: 20px;
            top: 50%;
            transform: translateY(-50%);
            opacity: 0.5;
            color: var(--accent-color);
        }

        .item-list {
            list-style: none;
            display: flex;
            flex-direction: column;
            gap: 12px;
        }

        .list-item {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid var(--glass-border);
            border-radius: 20px;
            padding: 16px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.23, 1, 0.32, 1);
        }

        .list-item:hover {
            background: rgba(255, 255, 255, 0.08);
            border-color: color-mix(in srgb, var(--accent-color), transparent 50%);
            transform: translateX(8px);
        }

        .list-item-info {
            flex: 1;
        }

        .list-item-title {
            font-weight: 600;
            display: block;
            margin-bottom: 2px;
        }

        .list-item-artist {
            font-size: 0.85rem;
            color: var(--text-dim);
        }

        .list-item-btn {
            background: color-mix(in srgb, var(--accent-color), transparent 90%);
            color: var(--accent-color);
            border: 1px solid color-mix(in srgb, var(--accent-color), transparent 70%);
            padding: 8px 16px;
            border-radius: 12px;
            font-size: 0.8rem;
            font-weight: 600;
            transition: all 0.2s ease;
        }

        .list-item:hover .list-item-btn {
            background: var(--accent-color);
            color: #000;
        }

        /* YouTube Dropper */
        .yt-card {
            border: 1px solid color-mix(in srgb, #ff0000, transparent 70%);
            background: linear-gradient(135deg, rgba(255, 0, 0, 0.05), transparent);
        }

        .yt-input-group {
            display: flex;
            gap: 10px;
        }

        .yt-input {
            flex: 1;
            background: rgba(0, 0, 0, 0.2);
            border: 1px solid rgba(255, 0, 0, 0.2);
            padding: 12px 16px;
            border-radius: 12px;
            color: #fff;
            outline: none;
        }

        .yt-btn {
            background: #ff0000;
            color: #fff;
            border: none;
            padding: 0 20px;
            border-radius: 12px;
            font-weight: 700;
            cursor: pointer;
            box-shadow: 0 0 15px rgba(255, 0, 0, 0.3);
        }

        /* Overlay */
        #overlay, #pin-overlay {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            background: rgba(0, 0, 0, 0.9);
            backdrop-filter: blur(20px);
            z-index: 9999;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }

        /* Custom Scrollbar */
        ::-webkit-scrollbar { width: 8px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.1); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.2); }
    </style>
</head>
<body>
    <div class="container">
        <h1>RADIONT</h1>

        <!-- Mode Switcher -->
        <div class="mode-switcher">
            <div id="mode-slider" class="mode-slider"></div>
            <button id="mode-btn-radio" class="mode-btn active" onclick="switchMode('radio')">
                <svg viewBox="0 0 24 24" fill="currentColor"><path d="M20,6H4V20H20V6M20,4C21.11,4 22,4.89 22,6V20C22,21.11 21.11,22 20,22H4C2.9,22 2,21.11 2,20V6C2,4.89 2.9,4 4,4H8L10,2H14L16,4H20M8,12A4,4 0 0,1 12,8A4,4 0 0,1 16,12A4,4 0 0,1 12,16A4,4 0 0,1 8,12M10,12A2,2 0 0,0 12,14A2,2 0 0,0 14,12A2,2 0 0,0 12,10A2,2 0 0,0 10,12Z"/></svg>
                RÁDIÓ
            </button>
            <button id="mode-btn-music" class="mode-btn" onclick="switchMode('music')">
                <svg viewBox="0 0 24 24" fill="currentColor"><path d="M21,3V15.5A3.5,3.5 0 0,1 17.5,19A3.5,3.5 0 0,1 14,15.5A3.5,3.5 0 0,1 17.5,12C18.04,12 18.55,12.13 19,12.36V6.47L9,8.6V17.5A3.5,3.5 0 0,1 5.5,21A3.5,3.5 0 0,1 2,17.5A3.5,3.5 0 0,1 5.5,14C6.04,14 6.55,14.13 7,14.36V4L21,1V3Z"/></svg>
                ZENE
            </button>
        </div>

        <!-- Main Player Card -->
        <div id="player-main-card" class="glass-card player-main">
            <div id="phone-now-playing">
                <span class="song-artist-main">Betöltés...</span>
                <span class="song-title-main">Várakozás a telefonra</span>
            </div>

            <!-- Progress Bar -->
            <div class="progress-container" id="progress-area" style="display: none;">
                <div class="progress-time">
                    <span id="time-current">0:00</span>
                    <span id="time-total">0:00</span>
                </div>
                <input type="range" id="progress-slider" value="0" step="1" oninput="onSeekStart()" onchange="onSeekEnd(this.value)">
            </div>

            <!-- Volume -->
            <div style="display: flex; align-items: center; gap: 15px; margin: 24px 0 10px;">
                <svg style="width: 20px; opacity: 0.5;" viewBox="0 0 24 24" fill="currentColor"><path d="M14,3.23V5.29C16.89,6.15 19,8.83 19,12C19,15.17 16.89,17.85 14,18.71V20.77C18.01,19.86 21,16.28 21,12C21,7.72 18.01,4.14 14,3.23M16.5,12C16.5,10.23 15.5,8.71 14,7.97V16.02C15.5,15.29 16.5,13.77 16.5,12M3,9V15H7L12,20V4L7,9H3Z"/></svg>
                <input type="range" id="volume-slider" min="0" max="1" step="0.01" oninput="setVolume(this.value)">
            </div>

            <!-- Controls -->
            <div class="controls-row">
                <button class="ctrl-btn" onclick="remoteControl('prev')">
                    <svg style="width: 36px;" viewBox="0 0 24 24" fill="currentColor"><path d="M16,18L16,6L7.5,12L16,18M6,18H8V6H6V18Z"/></svg>
                </button>
                <button id="remote-toggle-btn" class="ctrl-btn play-pause-btn" onclick="remoteControl('toggle')">
                    ▶
                </button>
                <button class="ctrl-btn" onclick="remoteControl('next')">
                    <svg style="width: 36px;" viewBox="0 0 24 24" fill="currentColor"><path d="M6,18L14.5,12L6,6V18M16,6V18H18V6H16Z"/></svg>
                </button>
            </div>

            <!-- Browser Player (Hidden by default) -->
            <div id="browser-player-card" style="display: none; border-top: 1px solid var(--glass-border); padding-top: 20px; margin-top: 20px;">
                <span style="font-size: 0.8rem; opacity: 0.5; margin-bottom: 10px; display: block;">LEJÁTSZÁS EZEN AZ ESZKÖZÖN:</span>
                <span id="browser-now-playing" style="font-weight: 600; display: block; margin-bottom: 10px;">-</span>
                <audio id="remote-audio" controls></audio>
            </div>
        </div>

        <!-- YT Dropper -->
        <div id="yt-dropper-card" class="glass-card yt-card" style="display: none;">
            <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 15px;">
                <svg style="width: 24px; color: #ff0000;" viewBox="0 0 24 24" fill="currentColor"><path d="M10,15L15.19,12L10,9V15M21.56,7.17C21.69,7.66 21.78,8.27 21.84,9C21.91,9.73 21.94,10.5 21.94,11.25V12.75C21.94,13.5 21.91,14.27 21.84,15C21.78,15.73 21.69,16.34 21.56,16.83C21.43,17.32 21.23,17.71 20.95,18C20.68,18.29 20.3,18.47 19.81,18.54C19.32,18.61 18.61,18.69 17.67,18.77C16.73,18.84 15.5,18.91 14,18.94L12,18.95L10,18.94C8.5,18.91 7.27,18.84 6.33,18.77C5.39,18.69 4.68,18.61 4.19,18.54C3.7,18.47 3.32,18.29 3.05,18C2.77,17.71 2.57,17.32 2.44,16.83C2.31,16.34 2.22,15.73 2.16,15C2.09,14.27 2.06,13.5 2.06,12.75V11.25C2.06,10.5 2.09,9.73 2.16,9C2.22,8.27 2.31,7.66 2.44,7.17C2.57,6.68 2.77,6.29 3.05,6C3.32,5.71 3.7,5.53 4.19,5.46C4.68,5.39 5.39,5.31 6.33,5.23C7.27,5.16 8.5,5.09 10,5.06L12,5.05L14,5.06C15.5,5.09 16.73,5.16 17.67,5.23C18.61,5.31 19.32,5.39 19.81,5.46C20.3,5.53 20.68,5.71 20.95,6C21.23,6.29 21.43,6.68 21.56,7.17Z"/></svg>
                <span style="font-family: 'Orbitron', sans-serif; font-weight: 700; letter-spacing: 1px;">YOUTUBE LINK BEDOBÓ</span>
            </div>
            <div class="yt-input-group">
                <input type="text" id="yt-url-input" class="yt-input" placeholder="Illeszd be a linket...">
                <button class="yt-btn" onclick="downloadYoutube()">LETÖLTÉS</button>
            </div>
            <div id="yt-status" style="margin-top: 10px; font-size: 0.8rem; opacity: 0.7;"></div>
        </div>

        <!-- Search -->
        <div class="search-box">
            <svg class="search-icon-abs" style="width: 20px;" viewBox="0 0 24 24" fill="currentColor"><path d="M9.5,3A6.5,6.5 0 0,1 16,9.5C16,11.11 15.41,12.59 14.44,13.73L14.71,14H15.5L20.5,19L19,20.5L14,15.5V14.71L13.73,14.44C12.59,15.41 11.11,16 9.5,16A6.5,6.5 0 0,1 3,9.5A6.5,6.5 0 0,1 9.5,3M9.5,5C7,5 5,7 5,9.5C5,12 7,14 9.5,14C12,14 14,12 14,9.5C14,7 12,5 9.5,5Z"/></svg>
            <input type="text" id="search-input" class="search-input" placeholder="Keresés..." oninput="handleSearch(this.value)">
        </div>

        <!-- List Section -->
        <div id="music-library-section">
            <div id="list-status" style="margin-bottom: 15px; font-size: 0.9rem; opacity: 0.5; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;">ZENE KÖNYVTÁR</div>
            <ul id="content-list" class="item-list"></ul>
        </div>
    </div>

    <!-- PIN Overlay -->
    <div id="pin-overlay" style="display: none;">
        <h2 style="font-family: 'Orbitron', sans-serif; margin-bottom: 30px; letter-spacing: 2px;">ADJA MEG A PIN KÓDOT</h2>
        <div id="pin-display" style="font-size: 2rem; letter-spacing: 10px; margin-bottom: 40px; color: var(--accent-color); text-shadow: 0 0 15px var(--accent-color);"></div>
        <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; width: 100%; max-width: 300px;">
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('1')">1</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('2')">2</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('3')">3</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('4')">4</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('5')">5</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('6')">6</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('7')">7</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('8')">8</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('9')">9</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.1); padding: 20px; font-size: 1.2rem;" onclick="clearPin()">C</button>
            <button class="mode-btn" style="background: rgba(255,255,255,0.05); padding: 20px; font-size: 1.5rem;" onclick="appendPin('0')">0</button>
            <button class="mode-btn" style="background: var(--accent-color); color: #000; padding: 20px; font-size: 1.2rem;" onclick="submitPin()">OK</button>
        </div>
        <button id="guest-btn" style="margin-top: 30px; background: transparent; border: 1px solid rgba(255,255,255,0.2); color: var(--text-dim); padding: 10px 20px; border-radius: 20px; font-size: 0.9rem; font-family: 'Outfit', sans-serif; cursor: pointer; display: none; transition: all 0.3s;" onmouseover="this.style.background='rgba(255,255,255,0.1)'; this.style.color='#fff'" onmouseout="this.style.background='transparent'; this.style.color='var(--text-dim)'" onclick="enterGuestMode()">Hallgatás vendégként</button>
    </div>

    <!-- Top Bar for Logout / Login -->
    <div id="top-bar" style="display: none; position: fixed; top: 0; left: 0; width: 100%; background: rgba(0,0,0,0.8); backdrop-filter: blur(10px); padding: 10px 20px; z-index: 1000; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--glass-border);">
        <span id="top-bar-status" style="font-size: 0.8rem; opacity: 0.7; font-weight: 600; letter-spacing: 1px;"></span>
        <button id="top-bar-btn" class="btn" style="padding: 6px 15px; font-size: 0.75rem;" onclick="logout()">Kijelentkezés</button>
    </div>

    <!-- Loading Overlay -->
    <div id="overlay">
        <div style="width: 40px; height: 40px; border: 4px solid rgba(255,255,255,0.1); border-top-color: var(--accent-color); border-radius: 50%; animation: spin 1s linear infinite;"></div>
        <div style="margin-top: 20px; font-family: 'Orbitron', sans-serif; letter-spacing: 2px;">KAPCSOLÓDÁS...</div>
    </div>

    <style>
        @keyframes spin { to { transform: rotate(360deg); } }
    </style>

    <script>
        const audio = document.getElementById('remote-audio');
        const phoneNowPlaying = document.getElementById('phone-now-playing');
        const browserNowPlaying = document.getElementById('browser-now-playing');
        const browserPlayerCard = document.getElementById('browser-player-card');
        const remoteToggleBtn = document.getElementById('remote-toggle-btn');
        const volumeSlider = document.getElementById('volume-slider');
        const progressSlider = document.getElementById('progress-slider');
        const progressArea = document.getElementById('progress-area');
        const timeCurrent = document.getElementById('time-current');
        const timeTotal = document.getElementById('time-total');
        
        const modeBtnRadio = document.getElementById('mode-btn-radio');
        const modeBtnMusic = document.getElementById('mode-btn-music');
        const modeSlider = document.getElementById('mode-slider');
        const playerMainCard = document.getElementById('player-main-card');
        const musicLibrarySection = document.getElementById('music-library-section');
        const ytDropperCard = document.getElementById('yt-dropper-card');
        const ytUrlInput = document.getElementById('yt-url-input');
        const ytStatus = document.getElementById('yt-status');

        const overlay = document.getElementById('overlay');
        const pinOverlay = document.getElementById('pin-overlay');
        const pinDisplay = document.getElementById('pin-display');

        let allSongs = [];
        let allStations = [];
        let isUserAdjustingVolume = false;
        let isUserSeeking = false;
        let currentMode = 'radio';
        let currentPin = localStorage.getItem('radiont_pin') || '';
        let isGuest = localStorage.getItem('radiont_is_guest') === 'true';
        let localLastLibraryUpdate = 0;

        function getAuthUrl(url) {
            if (isGuest && !url.startsWith('/remote/')) return url;
            const separator = url.includes('?') ? '&' : '?';
            return `${url}${separator}pin=${currentPin}`;
        }

        function appendPin(num) {
            if (currentPin.length < 6) {
                currentPin += num;
                updatePinDisplay();
            }
        }

        function clearPin() {
            currentPin = '';
            updatePinDisplay();
        }

        function updatePinDisplay() {
            pinDisplay.innerText = '*'.repeat(currentPin.length);
        }

        function submitPin() {
            isGuest = false;
            localStorage.removeItem('radiont_is_guest');
            localStorage.setItem('radiont_pin', currentPin);
            pinOverlay.style.display = 'none';
            checkStatus();
        }

        function enterGuestMode() {
            isGuest = true;
            localStorage.setItem('radiont_is_guest', 'true');
            pinOverlay.style.display = 'none';
            checkStatus();
        }

        function logout() {
            isGuest = false;
            localStorage.removeItem('radiont_is_guest');
            localStorage.removeItem('radiont_pin');
            clearPin();
            
            // Leállítjuk a helyi lejátszást
            audio.pause();
            audio.currentTime = 0;
            browserPlayerCard.style.display = 'none';
            
            pinOverlay.style.display = 'flex';
            document.getElementById('top-bar').style.display = 'none';
            checkStatus();
        }

        function formatTime(ms) {
            if (!ms || isNaN(ms)) return '0:00';
            const totalSeconds = Math.floor(ms / 1000);
            const minutes = Math.floor(totalSeconds / 60);
            const seconds = totalSeconds % 60;
            return `${minutes}:${seconds.toString().padStart(2, '0')}`;
        }

        async function loadContent() {
            try {
                if (currentMode === 'music') {
                    const response = await fetch(getAuthUrl('/songs'));
                    allSongs = await response.json();
                    renderSongs(allSongs);
                } else {
                    const response = await fetch(getAuthUrl('/stations'));
                    allStations = await response.json();
                    renderStations(allStations);
                }
            } catch (e) {
                console.error('Hiba a betöltéskor.');
            }
        }

        function renderSongs(songs) {
            const list = document.getElementById('content-list');
            const status = document.getElementById('list-status');
            status.innerText = `ZENETÁR (${songs.length} DAL)`;
            list.innerHTML = '';
            
            if (songs.length === 0) {
                list.innerHTML = '<div style="text-align: center; padding: 40px; opacity: 0.5;">Nincs találat</div>';
                return;
            }

            songs.forEach(song => {
                const li = document.createElement('li');
                li.className = 'list-item';
                li.onclick = () => playHere(song);
                li.innerHTML = `
                    <div class="list-item-info">
                        <span class="list-item-title">${song.title}</span>
                        <span class="list-item-artist">${song.artist}</span>
                    </div>
                    <button class="list-item-btn" style="display: ${isGuest ? 'none' : 'block'}" onclick="event.stopPropagation(); playOnPhone(${song.id})">📲 TELEFONON</button>
                `;
                list.appendChild(li);
            });
        }

        function renderStations(stations) {
            const list = document.getElementById('content-list');
            const status = document.getElementById('list-status');
            status.innerText = `RÁDIÓÁLLOMÁSOK (${stations.length})`;
            list.innerHTML = '';
            
            if (stations.length === 0) {
                list.innerHTML = '<div style="text-align: center; padding: 40px; opacity: 0.5;">Nincs állomás</div>';
                return;
            }

            stations.forEach(station => {
                const li = document.createElement('li');
                li.className = 'list-item';
                li.onclick = () => isGuest ? playStationHere(station) : playStationOnPhone(station.id);
                li.innerHTML = `
                    <div class="list-item-info">
                        <span class="list-item-title">${station.name}</span>
                        <span class="list-item-artist">${station.nowPlaying || 'Stream Online'}</span>
                    </div>
                    <button class="list-item-btn" style="display: ${isGuest ? 'none' : 'block'}" onclick="event.stopPropagation(); playStationOnPhone(${station.id})">📲 VÁLTÁS</button>
                `;
                list.appendChild(li);
            });
        }

        function handleSearch(query) {
            if (currentMode === 'music') {
                const filtered = allSongs.filter(song => 
                    song.title.toLowerCase().includes(query.toLowerCase()) || 
                    song.artist.toLowerCase().includes(query.toLowerCase())
                );
                renderSongs(filtered);
            } else {
                const filtered = allStations.filter(station => 
                    station.name.toLowerCase().includes(query.toLowerCase())
                );
                renderStations(filtered);
            }
        }

        function playHere(song) {
            browserPlayerCard.style.display = 'block';
            playerMainCard.style.display = 'block';
            browserNowPlaying.innerText = `${song.artist} - ${song.title}`;
            audio.src = getAuthUrl(`/stream/${song.id}`);
            audio.play();
        }

        function playStationHere(station) {
            browserPlayerCard.style.display = 'block';
            playerMainCard.style.display = 'block';
            browserNowPlaying.innerText = station.name;
            audio.src = station.url;
            audio.play();
        }

        async function playOnPhone(id) {
            try {
                await fetch(getAuthUrl(`/remote/play/${id}`));
                checkStatus();
            } catch (e) {
                console.error('Hiba a vezérléskor.');
            }
        }

        async function playStationOnPhone(id) {
            try {
                await fetch(getAuthUrl(`/remote/play/radio/${id}`));
                checkStatus();
            } catch (e) {
                console.error('Hiba a váltáskor.');
            }
        }

        async function remoteControl(action) {
            try {
                await fetch(getAuthUrl(`/remote/${action}`));
                checkStatus();
            } catch (e) {
                console.error('Hiba a vezérléskor.');
            }
        }

        async function switchMode(mode) {
            try {
                await fetch(getAuthUrl(`/remote/mode/${mode}`));
                checkStatus();
            } catch (e) {
                console.error('Hiba a módváltáskor.');
            }
        }

        async function setVolume(val) {
            isUserAdjustingVolume = true;
            try {
                await fetch(getAuthUrl(`/remote/volume/${val}`));
            } catch (e) {}
            setTimeout(() => { isUserAdjustingVolume = false; }, 1000);
        }

        function onSeekStart() {
            isUserSeeking = true;
        }

        async function onSeekEnd(val) {
            try {
                await fetch(getAuthUrl(`/remote/seek/${val}`));
            } catch (e) {}
            setTimeout(() => { isUserSeeking = false; }, 500);
        }

        async function downloadYoutube() {
            const url = ytUrlInput.value.trim();
            if (!url) return;
            
            ytStatus.innerText = "Küldés a telefonra...";
            try {
                const encoded = encodeURIComponent(url);
                await fetch(getAuthUrl(`/remote/yt-download/${encoded}`));
                ytStatus.innerText = "A telefonon elindult a letöltés!";
                ytUrlInput.value = "";
                setTimeout(() => { ytStatus.innerText = ""; }, 5000);
            } catch (e) {
                ytStatus.innerText = "Hiba a küldés során.";
            }
        }

        let isReady = false;

        async function checkStatus() {
            try {
                const response = await fetch(getAuthUrl('/status'));
                if (!response.ok) {
                    if (response.status === 403) {
                        const data = await response.json().catch(() => ({}));
                        if (data.guestModeEnabled) {
                            document.getElementById('guest-btn').style.display = 'block';
                        } else {
                            document.getElementById('guest-btn').style.display = 'none';
                        }
                        pinOverlay.style.display = 'flex';
                        overlay.style.display = 'none';
                        return;
                    }
                    throw new Error();
                }
                const data = await response.json();

                if (data.authRequired && (!isGuest || !data.guestModeEnabled)) {
                    if (data.guestModeEnabled) {
                        document.getElementById('guest-btn').style.display = 'block';
                    } else {
                        document.getElementById('guest-btn').style.display = 'none';
                    }
                    pinOverlay.style.display = 'flex';
                    overlay.style.display = 'none';
                    return;
                }

                pinOverlay.style.display = 'none';
                overlay.style.display = 'none';
                
                // Guest UI logic
                isGuest = data.isGuest;
                const topBar = document.getElementById('top-bar');
                const topBarStatus = document.getElementById('top-bar-status');
                const topBarBtn = document.getElementById('top-bar-btn');
                
                if (data.authRequired && isGuest) {
                     topBar.style.display = 'flex';
                     topBarStatus.innerText = 'VENDÉG MÓD (Csak hallgatás)';
                     topBarBtn.innerText = 'Bejelentkezés';
                } else if (!data.authRequired && currentPin) {
                     topBar.style.display = 'flex';
                     topBarStatus.innerText = 'TELJES HOZZÁFÉRÉS';
                     topBarBtn.innerText = 'Kijelentkezés';
                } else {
                     topBar.style.display = 'none';
                }
                
                const controlsToHide = document.querySelectorAll('.controls-row, #volume-slider, .mode-switcher, #yt-dropper-card, #phone-now-playing, #progress-area');
                controlsToHide.forEach(el => {
                    if (!el) return;
                    el.style.display = isGuest ? 'none' : '';
                    if (el.id === 'volume-slider' && el.parentElement) el.parentElement.style.display = isGuest ? 'none' : 'flex';
                    if (el.id === 'yt-dropper-card' && !isGuest) el.style.display = (data.isWebDownloadEnabled && currentMode === 'music') ? 'block' : 'none';
                });
                
                if (isGuest && browserPlayerCard.style.display === 'none') {
                    playerMainCard.style.display = 'none';
                } else if (currentMode === 'music' && !data.nowPlaying && !isGuest && browserPlayerCard.style.display === 'none') {
                    playerMainCard.style.display = 'none';
                } else {
                    playerMainCard.style.display = 'block';
                }
                
                if (data.themeColor) {
                    document.documentElement.style.setProperty('--accent-color', data.themeColor);
                }
                
                const modeChanged = currentMode !== (data.isMusicMode ? 'music' : 'radio');
                currentMode = data.isMusicMode ? 'music' : 'radio';

                ytDropperCard.style.display = (!isGuest && data.isWebDownloadEnabled && data.isMusicMode) ? 'block' : 'none';

                const libraryUpdated = data.lastLibraryUpdate && data.lastLibraryUpdate > localLastLibraryUpdate;
                if (libraryUpdated) {
                    localLastLibraryUpdate = data.lastLibraryUpdate;
                }

                if (!isReady || modeChanged || libraryUpdated) {
                    loadContent();
                    isReady = true;
                }

                modeBtnRadio.classList.toggle('active', currentMode === 'radio');
                modeBtnMusic.classList.toggle('active', currentMode === 'music');
                modeSlider.style.transform = currentMode === 'music' ? 'translateX(100%)' : 'translateX(0)';
                
                // Csak akkor mutassuk a lejátszót zenénél, ha van kiválasztott dal
                if (currentMode === 'music' && !data.nowPlaying) {
                    playerMainCard.style.display = 'none';
                } else {
                    playerMainCard.style.display = 'block';
                }
                
                if (currentMode === 'radio' && !isGuest) {
                    browserPlayerCard.style.display = 'none';
                    audio.pause();
                }

                if (data.nowPlaying && !isGuest) {
                    phoneNowPlaying.querySelector('.song-artist-main').innerText = (currentMode === 'music' ? 'MOST SZÓL A TELEFONON:' : 'AKTUÁLIS RÁDIÓADÓ:');
                    phoneNowPlaying.querySelector('.song-title-main').innerText = data.nowPlaying.title;
                    if (data.nowPlaying.artist) {
                        phoneNowPlaying.querySelector('.song-artist-main').innerText = data.nowPlaying.artist;
                    }
                    remoteToggleBtn.innerText = data.nowPlaying.isPlaying ? '⏸' : '▶';
                    
                    if (currentMode === 'music' && data.duration > 0) {
                        progressArea.style.display = 'block';
                        if (!isUserSeeking) {
                            progressSlider.max = data.duration;
                            progressSlider.value = data.position;
                        }
                        timeCurrent.innerText = formatTime(data.position);
                        timeTotal.innerText = formatTime(data.duration);
                    } else {
                        progressArea.style.display = 'none';
                    }
                }

                if (!isUserAdjustingVolume) {
                    volumeSlider.value = data.volume;
                }

            } catch (e) {
                overlay.style.display = 'flex';
                overlay.innerHTML = '<div style="color: #ff4444; font-family: \'Orbitron\', sans-serif;">MEGSZAKADT A KAPCSOLAT...</div>';
                isReady = false;
            }
        }

        setInterval(checkStatus, 1000);
        checkStatus();
    </script>
</body>
</html>
''';
  }
}
