import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/foundation.dart';
import '../providers/music_provider.dart';

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

  bool get isRunning => _isRunning;
  String? get url => _ip != null ? 'http://$_ip:$port' : null;

  Future<void> startServer(MusicProvider musicProvider, dynamic radioProvider, {bool pinEnabled = false, String? pin}) async {
    if (_isRunning) return;
    _pinEnabled = pinEnabled;
    _pin = pin;

    try {
      final info = NetworkInfo();
      _ip = await info.getWifiIP();
      
      var handler = const Pipeline()
          .addMiddleware(logRequests())
          .addHandler((request) => _handleRequest(request, musicProvider, radioProvider));

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

  Future<Response> _handleRequest(Request request, MusicProvider musicProvider, dynamic radioProvider) async {
    final path = request.url.path;
    final bool isMusicMode = musicProvider.isMusicModeActive;

    if (path == '' || path == 'index.html') {
      return Response.ok(_getHtmlContent(), headers: {'Content-Type': 'text/html; charset=utf-8'});
    }

    // PIN ellenőrzés az API hívásokhoz
    if (_pinEnabled && _pin != null) {
      final queryPin = request.url.queryParameters['pin'];
      if (queryPin != _pin) {
        if (path == 'status') {
          return Response.ok(jsonEncode({'isReady': true, 'authRequired': true}), 
              headers: {'Content-Type': 'application/json'});
        }
        return Response.forbidden('Érvénytelen PIN kód.');
      }
    }

    if (path == 'status') {
      Map<String, dynamic> status = {
        'isReady': true, 
        'authRequired': false,
        'isMusicMode': isMusicMode,
        'isLoading': isMusicMode ? musicProvider.isLoading : radioProvider.isLoading,
        'volume': isMusicMode ? musicProvider.systemVolume : radioProvider.systemVolume,
        'isWebDownloadEnabled': musicProvider.isWebRemoteDownloadEnabled,
        'lastLibraryUpdate': musicProvider.lastLibraryUpdate,
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
    <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700&family=Inter:wght@300;400;600&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #00e5ff;
            --secondary: #d500f9;
            --bg: #0a1114;
            --card: #141e24;
            --text: #e0e0e0;
        }
        body {
            font-family: 'Inter', sans-serif;
            background-color: var(--bg);
            color: var(--text);
            margin: 0;
            padding: 20px;
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        h1 {
            font-family: 'Orbitron', sans-serif;
            color: var(--primary);
            text-transform: uppercase;
            letter-spacing: 3px;
            margin-bottom: 20px;
            text-shadow: 0 0 10px rgba(0, 229, 255, 0.5);
        }
        .container {
            width: 100%;
            max-width: 800px;
        }
        
        .mode-switcher {
            display: flex;
            width: 100%;
            background: var(--card);
            border-radius: 15px;
            padding: 5px;
            margin-bottom: 20px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.3);
            border: 1px solid rgba(255,255,255,0.05);
        }
        .mode-btn {
            flex: 1;
            padding: 12px;
            border: none;
            background: transparent;
            color: var(--text);
            font-family: 'Orbitron', sans-serif;
            font-size: 0.9rem;
            cursor: pointer;
            border-radius: 10px;
            transition: all 0.3s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
            opacity: 0.6;
        }
        .mode-btn.active {
            background: var(--primary);
            color: #000;
            opacity: 1;
            box-shadow: 0 0 15px rgba(0, 229, 255, 0.4);
        }
        .mode-btn svg {
            width: 20px;
            height: 20px;
        }

        .player-card {
            background: var(--card);
            border-radius: 20px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            display: flex;
            flex-direction: column;
            align-items: center;
            border: 1px solid rgba(0, 229, 255, 0.1);
        }
        #browser-player-card {
            border-color: var(--secondary);
            animation: pulse-glow 2s infinite;
        }
        @keyframes pulse-glow {
            0% { box-shadow: 0 0 10px rgba(213, 0, 249, 0.2); }
            50% { box-shadow: 0 0 25px rgba(213, 0, 249, 0.4); }
            100% { box-shadow: 0 0 10px rgba(213, 0, 249, 0.2); }
        }

        audio {
            width: 100%;
            margin-top: 15px;
            filter: invert(100%) hue-rotate(180deg) brightness(1.5);
        }
        
        .search-container {
            width: 100%;
            margin-bottom: 20px;
            position: relative;
        }
        .search-input {
            width: 100%;
            background: var(--card);
            border: 1px solid rgba(0, 229, 255, 0.2);
            padding: 12px 15px 12px 45px;
            border-radius: 12px;
            color: var(--text);
            font-family: 'Inter', sans-serif;
            font-size: 1rem;
            outline: none;
            transition: all 0.3s ease;
            box-sizing: border-box;
        }
        .search-input:focus {
            border-color: var(--primary);
            box-shadow: 0 0 15px rgba(0, 229, 255, 0.2);
        }
        .search-icon {
            position: absolute;
            left: 15px;
            top: 50%;
            transform: translateY(-50%);
            color: var(--primary);
            opacity: 0.7;
            pointer-events: none;
        }
        
        .volume-container {
            width: 100%;
            margin-top: 15px;
            display: flex;
            align-items: center;
            gap: 15px;
            padding: 0 10px;
            box-sizing: border-box;
        }
        .volume-icon {
            color: var(--primary);
            opacity: 0.8;
            width: 24px;
            display: flex;
            justify-content: center;
        }
        .volume-slider-wrapper {
            flex: 1;
            position: relative;
            display: flex;
            align-items: center;
        }
        .volume-slider {
            -webkit-appearance: none;
            width: 100%;
            height: 6px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            outline: none;
            cursor: pointer;
            transition: background 0.3s;
        }
        .volume-slider::-webkit-slider-thumb {
            -webkit-appearance: none;
            appearance: none;
            width: 18px;
            height: 18px;
            background: var(--primary);
            border-radius: 50%;
            cursor: pointer;
            box-shadow: 0 0 10px var(--primary);
            border: 2px solid var(--bg);
            transition: all 0.2s ease-in-out;
        }

        .progress-container {
            width: 100%;
            margin-bottom: 10px;
            display: flex;
            flex-direction: column;
            gap: 5px;
            padding: 0 10px;
            box-sizing: border-box;
        }
        .progress-slider-wrapper {
            width: 100%;
            position: relative;
            display: flex;
            align-items: center;
        }
        .progress-slider {
            -webkit-appearance: none;
            width: 100%;
            height: 8px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            outline: none;
            cursor: pointer;
        }
        .progress-slider::-webkit-slider-thumb {
            -webkit-appearance: none;
            appearance: none;
            width: 20px;
            height: 20px;
            background: var(--secondary);
            border-radius: 50%;
            cursor: pointer;
            box-shadow: 0 0 15px var(--secondary);
            border: 2px solid var(--bg);
            transition: all 0.2s ease-in-out;
        }
        .progress-time {
            display: flex;
            justify-content: space-between;
            font-size: 0.75em;
            color: var(--text);
            opacity: 0.6;
            font-family: 'Orbitron', sans-serif;
        }

        .song-list {
            list-style: none;
            padding: 0;
            width: 100%;
        }
        .song-item {
            background: var(--card);
            margin: 10px 0;
            padding: 15px;
            border-radius: 12px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            transition: all 0.3s ease;
            border: 1px solid rgba(255,255,255,0.05);
        }
        .song-item:hover {
            background: rgba(0, 229, 255, 0.1);
            transform: translateX(5px);
            border-color: var(--primary);
        }
        .song-info {
            display: flex;
            flex-direction: column;
            flex: 1;
        }
        .song-title {
            font-weight: 600;
            color: #fff;
        }
        .song-artist {
            font-size: 0.85em;
            color: #aaa;
        }
        .actions {
            display: flex;
            gap: 10px;
        }
        .btn {
            background: rgba(255,255,255,0.1);
            border: 1px solid rgba(255,255,255,0.2);
            color: #fff;
            padding: 10px 15px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 0.9em;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .btn:hover {
            background: var(--primary);
            color: #000;
        }
        .btn-remote {
            border-color: var(--primary);
            color: var(--primary);
        }
        #current-title {
            font-weight: bold;
            color: var(--primary);
        }
        
        #overlay {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            background: var(--bg);
            z-index: 9999;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            text-align: center;
            padding: 20px;
        }
        .spinner {
            width: 50px;
            height: 50px;
            border: 5px solid rgba(0, 229, 255, 0.1);
            border-top: 5px solid var(--primary);
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin-bottom: 20px;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }

        /* PIN Overlay */
        #pin-overlay {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            background: var(--bg);
            z-index: 10000;
            display: none;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .pin-pad {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 15px;
            margin-top: 30px;
            max-width: 300px;
        }
        .pin-btn {
            width: 70px;
            height: 70px;
            border-radius: 50%;
            border: 1px solid rgba(0, 229, 255, 0.3);
            background: rgba(255,255,255,0.05);
            color: var(--text);
            font-size: 1.5rem;
            font-family: 'Orbitron', sans-serif;
            cursor: pointer;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .pin-btn:hover {
            background: var(--primary);
            color: #000;
            box-shadow: 0 0 15px var(--primary);
        }
        .pin-display {
            font-size: 2rem;
            letter-spacing: 10px;
            margin-bottom: 20px;
            color: var(--primary);
            font-family: 'Orbitron', sans-serif;
            height: 40px;
        }
    </style>
</head>
<body>
    <div id="overlay">
        <div class="spinner"></div>
        <div id="overlay-msg" style="font-family: 'Orbitron', sans-serif; color: var(--primary);">
            Kapcsolódás a telefonhoz...
        </div>
    </div>

    <div id="pin-overlay">
        <h1>PIN Szükséges</h1>
        <div style="opacity: 0.7; margin-bottom: 20px;">A hozzáféréshez add meg a PIN kódot!</div>
        <div id="pin-display" class="pin-display"></div>
        <div class="pin-pad">
            <button class="pin-btn" onclick="appendPin('1')">1</button>
            <button class="pin-btn" onclick="appendPin('2')">2</button>
            <button class="pin-btn" onclick="appendPin('3')">3</button>
            <button class="pin-btn" onclick="appendPin('4')">4</button>
            <button class="pin-btn" onclick="appendPin('5')">5</button>
            <button class="pin-btn" onclick="appendPin('6')">6</button>
            <button class="pin-btn" onclick="appendPin('7')">7</button>
            <button class="pin-btn" onclick="appendPin('8')">8</button>
            <button class="pin-btn" onclick="appendPin('9')">9</button>
            <button class="pin-btn" onclick="clearPin()" style="font-size: 1rem; border-color: var(--secondary); color: var(--secondary);">Törlés</button>
            <button class="pin-btn" onclick="appendPin('0')">0</button>
            <button class="pin-btn" onclick="submitPin()" style="font-size: 1rem; border-color: var(--primary); color: var(--primary);">OK</button>
        </div>
    </div>
    
    <h1>Radiont Remote</h1>
    
    <div class="container">
        <!-- Mód választó -->
        <div class="mode-switcher">
            <button id="mode-btn-radio" class="mode-btn" onclick="switchMode('radio')">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="2"></circle><path d="M16.24 7.76a6 6 0 0 1 0 8.49m-8.48-.01a6 6 0 0 1 0-8.49m11.31-2.82a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14"></path></svg>
                RÁDIÓ
            </button>
            <button id="mode-btn-music" class="mode-btn" onclick="switchMode('music')">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>
                ZENE
            </button>
        </div>

        <!-- Most szól (Streaming - Csak Zene módban látszik a lista alatt) -->
        <div id="browser-player-card" class="player-card" style="display: none;">
            <div id="current-info" style="font-size: 0.9em; margin-bottom: 5px; opacity: 0.8;">Most szól itt (Böngésző):</div>
            <div id="current-title" style="font-weight: bold; margin-bottom: 10px;">-</div>
            <audio id="audio-player" controls></audio>
        </div>

        <!-- Távirányító + Most szól a telefonon -->
        <div class="player-card">
            <div style="font-weight: bold; margin-bottom: 15px; font-family: 'Orbitron', sans-serif; letter-spacing: 1px;">TELEFON VEZÉRLÉS</div>
            
            <div id="phone-now-playing" style="font-size: 0.9em; margin-bottom: 15px; color: var(--primary); text-align: center; min-height: 40px; display: flex; flex-direction: column; justify-content: center;">
                <span style="opacity: 0.5;">Betöltés...</span>
            </div>

            <!-- Idővonal (Csak Zene módban) -->
            <div class="progress-container" id="progress-container" style="display: none;">
                <div class="progress-slider-wrapper">
                    <input type="range" id="progress-slider" class="progress-slider" min="0" max="100" value="0" oninput="handleSeekInput(this.value)" onchange="handleSeekChange(this.value)">
                </div>
                <div class="progress-time">
                    <span id="time-current">0:00</span>
                    <span id="time-total">0:00</span>
                </div>
            </div>

            <div class="actions">
                <button class="btn" onclick="remoteAction('prev')">⏮ Előző</button>
                <button class="btn btn-remote" id="remote-toggle-btn" onclick="remoteAction('toggle')">▶ Play</button>
                <button class="btn" onclick="remoteAction('next')">⏭ Következő</button>
            </div>
            
            <!-- Hangerő szabályzó -->
            <div class="volume-container">
                <div class="volume-icon" id="vol-icon">
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"></path></svg>
                </div>
                <div class="volume-slider-wrapper">
                    <input type="range" id="volume-slider" class="volume-slider" min="0" max="1" step="0.01" value="0.5" oninput="setVolume(this.value)">
                </div>
            </div>
        </div>

        <!-- YouTube Dropper Section -->
        <div id="yt-dropper-card" class="player-card" style="display: none; border-color: #ff0000; background: linear-gradient(145deg, var(--card) 0%, #1a0000 100%);">
            <div style="font-weight: bold; margin-bottom: 10px; font-family: 'Orbitron', sans-serif; color: #ff0000; display: flex; align-items: center; gap: 8px;">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/></svg>
                YOUTUBE LINK BEDOBÓ
            </div>
            <div style="width: 100%; position: relative;">
                <input type="text" id="yt-url-input" class="search-input" placeholder="YouTube videó vagy Shorts link..." style="border-color: rgba(255, 0, 0, 0.3); padding-right: 100px;">
                <button class="btn" style="position: absolute; right: 5px; top: 5px; bottom: 5px; background: #ff0000; color: #fff; border: none; font-size: 0.8rem; font-weight: bold;" onclick="submitYtDownload()">
                    LETÖLTÉS
                </button>
            </div>
            <div id="yt-status" style="font-size: 0.75rem; margin-top: 8px; color: #aaa;">A zene a 'WebDownloads' mappába fog kerülni.</div>
        </div>

        <div id="music-library-section" style="display: none;">
            <div class="search-container">
                <svg class="search-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
                <input type="text" id="search-input" class="search-input" placeholder="Keresés zenék vagy előadók között..." oninput="handleSearch(this.value)">
            </div>

            <div id="status" style="margin-top: 10px; margin-bottom: 10px; font-size: 0.9em; opacity: 0.8;">Dalok betöltése...</div>
            <ul class="song-list" id="list"></ul>
        </div>
        
        <div style="margin-top: 40px; width: 100%; display: flex; justify-content: center; opacity: 0.4;">
            <button class="btn" style="font-size: 0.8rem; padding: 5px 10px;" onclick="logout()">🔒 Kijelentkezés (PIN törlése)</button>
        </div>
    </div>

    <script>
        const audio = document.getElementById('audio-player');
        const list = document.getElementById('list');
        const currentTitle = document.getElementById('current-title');
        const status = document.getElementById('status');
        const searchInput = document.getElementById('search-input');
        const phoneNowPlaying = document.getElementById('phone-now-playing');
        const remoteToggleBtn = document.getElementById('remote-toggle-btn');
        const volumeSlider = document.getElementById('volume-slider');
        const volIcon = document.getElementById('vol-icon');
        
        const progressContainer = document.getElementById('progress-container');
        const progressSlider = document.getElementById('progress-slider');
        const timeCurrent = document.getElementById('time-current');
        const timeTotal = document.getElementById('time-total');
        
        const modeBtnRadio = document.getElementById('mode-btn-radio');
        const modeBtnMusic = document.getElementById('mode-btn-music');
        const musicLibrarySection = document.getElementById('music-library-section');
        const browserPlayerCard = document.getElementById('browser-player-card');
        const ytDropperCard = document.getElementById('yt-dropper-card');
        const ytUrlInput = document.getElementById('yt-url-input');
        const ytStatus = document.getElementById('yt-status');

        const pinOverlay = document.getElementById('pin-overlay');
        const pinDisplay = document.getElementById('pin-display');

        let allSongs = [];
        let allStations = [];
        let isUserAdjustingVolume = false;
        let isUserSeeking = false;
        let currentMode = 'radio';
        let currentPin = localStorage.getItem('radiont_pin') || '';
        let localLastLibraryUpdate = 0;

        function getAuthUrl(url) {
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

        async function submitPin() {
            localStorage.setItem('radiont_pin', currentPin);
            pinOverlay.style.display = 'none';
            checkStatus();
        }

        function logout() {
            localStorage.removeItem('radiont_pin');
            currentPin = '';
            location.reload();
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
                status.innerText = 'Hiba a betöltéskor.';
            }
        }

        function renderSongs(songs) {
            status.innerText = `Összesen ${songs.length} dal találva`;
            list.innerHTML = '';
            searchInput.placeholder = "Keresés zenék vagy előadók között...";
            
            if (songs.length === 0) {
                list.innerHTML = '<div style="text-align: center; padding: 40px; opacity: 0.5;">Nincs találat</div>';
                return;
            }

            songs.forEach(song => {
                const li = document.createElement('li');
                li.className = 'song-item';
                li.innerHTML = `
                    <div class="song-info" onclick="playHere(${JSON.stringify(song).replace(/"/g, '&quot;')})">
                        <span class="song-title">${song.title}</span>
                        <span class="song-artist">${song.artist}</span>
                    </div>
                    <div class="actions">
                        <button class="btn btn-remote" onclick="playOnPhone(${song.id})">📲 Telefonon</button>
                    </div>
                `;
                list.appendChild(li);
            });
        }

        function renderStations(stations) {
            status.innerText = `${stations.length} rádióállomás elérhető`;
            list.innerHTML = '';
            searchInput.placeholder = "Keresés rádióadók között...";
            
            if (stations.length === 0) {
                list.innerHTML = '<div style="text-align: center; padding: 40px; opacity: 0.5;">Nincs állomás</div>';
                return;
            }

            stations.forEach(station => {
                const li = document.createElement('li');
                li.className = 'song-item';
                li.innerHTML = `
                    <div class="song-info" onclick="playStationOnPhone('${station.id}')">
                        <span class="song-title">${station.name}</span>
                        <span class="song-artist">${station.nowPlaying || 'Stream Online'}</span>
                    </div>
                    <div class="actions">
                        <button class="btn btn-remote" onclick="playStationOnPhone('${station.id}')">📲 Váltás</button>
                    </div>
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
            browserPlayerCard.style.display = 'flex';
            currentTitle.innerText = `${song.artist} - ${song.title}`;
            audio.src = getAuthUrl(`/stream/${song.id}`);
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
                console.error('Hiba a rádióváltáskor.');
            }
        }

        async function remoteAction(action) {
            try {
                await fetch(getAuthUrl(`/remote/${action}`));
                checkStatus();
            } catch (e) {
                console.error('Hiba a távirányításkor.');
            }
        }

        async function switchMode(mode) {
            try {
                await fetch(getAuthUrl(`/remote/mode/${mode}`));
                checkStatus();
            } catch (e) {
                console.error('Hiba a mód váltásakor.');
            }
        }

        async function setVolume(val) {
            isUserAdjustingVolume = true;
            updateVolumeIcon(val);
            try {
                await fetch(getAuthUrl(`/remote/volume/${val}`));
            } catch (e) {
                console.error('Hiba a hangerő állításakor.');
            }
            setTimeout(() => { isUserAdjustingVolume = false; }, 2000);
        }

        function updateVolumeIcon(val) {
            if (val == 0) {
                volIcon.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><line x1="23" y1="9" x2="17" y2="15"></line><line x1="17" y1="9" x2="23" y2="15"></line></svg>';
            } else if (val < 0.5) {
                volIcon.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><path d="M15.54 8.46a5 5 0 0 1 0 7.07"></path></svg>';
            } else {
                volIcon.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"></path></svg>';
            }
        }

        function handleSeekInput(val) {
            isUserSeeking = true;
            timeCurrent.innerText = formatTime(val);
        }

        async function handleSeekChange(val) {
            try {
                await fetch(getAuthUrl(`/remote/seek/${val}`));
            } catch (e) {
                console.error('Hiba a tekeréskor.');
            }
            setTimeout(() => { isUserSeeking = false; }, 1000);
        }

        async function submitYtDownload() {
            const url = ytUrlInput.value.trim();
            if (!url) return;
            
            ytStatus.innerText = 'Küldés a telefonra...';
            ytStatus.style.color = '#00e5ff';
            
            try {
                const encodedUrl = encodeURIComponent(url);
                await fetch(getAuthUrl(`/remote/yt-download/${encodedUrl}`));
                ytUrlInput.value = '';
                ytStatus.innerText = 'Sikeresen elküldve! A letöltés a háttérben elindult.';
                ytStatus.style.color = '#00ff00';
                setTimeout(() => {
                    ytStatus.innerText = "A zene a 'WebDownloads' mappába fog kerülni.";
                    ytStatus.style.color = '#aaa';
                }, 5000);
            } catch (e) {
                ytStatus.innerText = 'Hiba a küldés során.';
                ytStatus.style.color = '#ff0000';
            }
        }

        // Státusz ellenőrzése
        const overlay = document.getElementById('overlay');
        const overlayMsg = document.getElementById('overlay-msg');
        let isReady = false;

        async function checkStatus() {
            const startTime = Date.now();
            try {
                const response = await fetch(getAuthUrl('/status'));
                const data = await response.json();
                const rtt = Date.now() - startTime;
                const latency = rtt / 2;

                if (data.isReady) {
                    if (data.authRequired) {
                        pinOverlay.style.display = 'flex';
                        overlay.style.display = 'none';
                        return;
                    }

                    pinOverlay.style.display = 'none';
                    overlay.style.display = 'none';
                    
                    const modeChanged = currentMode !== (data.isMusicMode ? 'music' : 'radio');
                    currentMode = data.isMusicMode ? 'music' : 'radio';

                    ytDropperCard.style.display = (data.isWebDownloadEnabled && data.isMusicMode) ? 'flex' : 'none';

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
                    musicLibrarySection.style.display = currentMode === 'music' ? 'block' : 'none';

                    if (currentMode === 'radio') {
                        browserPlayerCard.style.display = 'none';
                        audio.pause();
                    }

                    if (data.nowPlaying) {
                        phoneNowPlaying.innerHTML = `
                            <span style="font-size: 0.8em; opacity: 0.7; margin-bottom: 2px;">${currentMode === 'music' ? 'Most szól a telefonon:' : 'Aktuális rádióadó:'}</span>
                            <span style="font-weight: 600;">${data.nowPlaying.title}</span>
                            <span style="font-size: 0.85em; opacity: 0.8;">${data.nowPlaying.artist || ''}</span>
                        `;
                        remoteToggleBtn.innerText = data.nowPlaying.isPlaying ? '⏸ Pause' : '▶ Play';
                        
                        if (currentMode === 'music' && data.duration > 0) {
                            progressContainer.style.display = 'flex';
                            if (!isUserSeeking) {
                                progressSlider.max = data.duration;
                                progressSlider.value = data.position;
                                timeCurrent.innerText = formatTime(data.position);
                                timeTotal.innerText = formatTime(data.duration);
                            }
                        } else {
                            progressContainer.style.display = 'none';
                        }
                    } else {
                        phoneNowPlaying.innerHTML = '<span style="opacity: 0.5;">A telefonon semmi nem szól.</span>';
                        remoteToggleBtn.innerText = '▶ Play';
                        progressContainer.style.display = 'none';
                    }

                    if (!isUserAdjustingVolume) {
                        volumeSlider.value = data.volume;
                        updateVolumeIcon(data.volume);
                    }
                } else {
                    overlay.style.display = 'flex';
                    overlayMsg.innerText = 'Betöltés...';
                    isReady = false;
                }
            } catch (e) {
                overlay.style.display = 'flex';
                overlayMsg.innerText = 'Megszakadt a kapcsolat a telefonnal.';
                isReady = false;
            }
        }

            setInterval(checkStatus, 1000);
            checkStatus();

            window.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible') {
                    checkStatus();
                }
            });
            window.addEventListener('focus', checkStatus);
    </script>
</body>
</html>
''' ;
  }
}
