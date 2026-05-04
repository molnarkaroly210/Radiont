// lib/services/streaming_service.dart

import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/foundation.dart';
import '../providers/music_provider.dart';

class StreamingService {
  HttpServer? _server;
  String? _ip;
  final int port = 8080;
  bool _isRunning = false;

  bool get isRunning => _isRunning;
  String? get url => _ip != null ? 'http://$_ip:$port' : null;

  static final StreamingService _instance = StreamingService._internal();
  factory StreamingService() => _instance;
  StreamingService._internal();

  Future<void> startServer(MusicProvider musicProvider) async {
    if (_isRunning) return;

    try {
      final info = NetworkInfo();
      _ip = await info.getWifiIP();
      if (_ip == null) {
        // Fallback: keressünk egy nem loopback IP-t
        final interfaces = await NetworkInterface.list();
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              _ip = addr.address;
              break;
            }
          }
          if (_ip != null) break;
        }
      }

      if (_ip == null) throw Exception("Nem sikerült meghatározni a helyi IP címet.");

      var handler = const Pipeline()
          .addMiddleware(logRequests())
          .addMiddleware(_corsMiddleware)
          .addHandler((Request request) => _handleRequest(request, musicProvider));

      _server = await io.serve(handler, InternetAddress.anyIPv4, port);
      _isRunning = true;
      debugPrint('Streaming szerver elindult: http://$_ip:$port');
    } catch (e) {
      debugPrint('Hiba a szerver indításakor: $e');
      _isRunning = false;
      rethrow;
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    debugPrint('Streaming szerver leállítva.');
  }

  final Middleware _corsMiddleware = (Handler handler) {
    return (Request request) async {
      final response = await handler(request);
      return response.change(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept',
      });
    };
  };

  Future<Response> _handleRequest(Request request, MusicProvider musicProvider) async {
    final path = request.url.path;

    if (path == '' || path == 'index.html') {
      return Response.ok(_getHtmlContent(), headers: {'Content-Type': 'text/html; charset=utf-8'});
    }

    if (path == 'status') {
      final currentSong = musicProvider.currentSong;
      return Response.ok(jsonEncode({
        'isReady': musicProvider.isMusicModeActive && !musicProvider.isLoading,
        'isMusicMode': musicProvider.isMusicModeActive,
        'isLoading': musicProvider.isLoading,
        'volume': musicProvider.systemVolume,
        'position': musicProvider.audioPlayer.position.inMilliseconds,
        'duration': musicProvider.audioPlayer.duration?.inMilliseconds ?? 0,
        'nowPlaying': currentSong != null ? {
          'title': musicProvider.getSongTitle(currentSong),
          'artist': musicProvider.getSongArtist(currentSong),
          'isPlaying': musicProvider.audioPlayer.playing,
        } : null
      }), headers: {'Content-Type': 'application/json'});
    }

    if (path == 'songs') {
      final songs = musicProvider.displayedSongs.map((s) => {
        'id': s.id,
        'title': s.title,
        'artist': s.artist ?? 'Ismeretlen',
        'album': s.album ?? 'Ismeretlen',
        'duration': s.duration,
      }).toList();
      return Response.ok(jsonEncode(songs), headers: {'Content-Type': 'application/json'});
    }

    // Távirányítás: Lejátszás a telefonon
    if (path.startsWith('remote/play/')) {
      final idStr = path.replaceFirst('remote/play/', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        final index = musicProvider.displayedSongs.indexWhere((s) => s.id == id);
        if (index != -1) {
          musicProvider.playSong(index);
          return Response.ok('Lejátszás indítva a telefonon.');
        }
      }
      return Response.notFound('Zene nem található.');
    }

    if (path == 'remote/next') {
      musicProvider.nextSong();
      return Response.ok('Következő.');
    }

    if (path == 'remote/prev') {
      musicProvider.previousSong();
      return Response.ok('Előző.');
    }

    if (path == 'remote/toggle') {
      musicProvider.togglePlayPause();
      return Response.ok('Lejátszás/Szünet váltva.');
    }

    if (path.startsWith('remote/volume/')) {
      final volStr = path.replaceFirst('remote/volume/', '');
      final vol = double.tryParse(volStr);
      if (vol != null) {
        musicProvider.setSystemVolume(vol);
        return Response.ok('Hangerő beállítva: $vol');
      }
      return Response.badRequest(body: 'Érvénytelen hangerő.');
    }

    if (path.startsWith('remote/seek/')) {
      final msStr = path.replaceFirst('remote/seek/', '');
      final ms = int.tryParse(msStr);
      if (ms != null) {
        musicProvider.audioPlayer.seek(
          Duration(milliseconds: ms),
          index: musicProvider.audioPlayer.currentIndex,
        );
        return Response.ok('Keresés befejezve.');
      }
      return Response.badRequest(body: 'Érvénytelen időpont.');
    }

    if (path.startsWith('stream/')) {
      final idStr = path.replaceFirst('stream/', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        final song = musicProvider.displayedSongs.where((s) => s.id == id).firstOrNull;
        if (song != null) {
          final file = File(song.data);
          if (await file.exists()) {
            return Response.ok(file.openRead(), headers: {
              'Content-Type': 'audio/mpeg',
              'Content-Length': (await file.length()).toString(),
              'Accept-Ranges': 'bytes',
            });
          }
        }
      }
      return Response.notFound('A kért zene nem található.');
    }

    return Response.notFound('Az oldal nem található.');
  }

  String _getHtmlContent() {
    return '''
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
            margin-bottom: 30px;
            text-shadow: 0 0 10px rgba(0, 229, 255, 0.5);
        }
        .container {
            width: 100%;
            max-width: 800px;
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
        audio {
            width: 100%;
            margin-top: 15px;
            filter: invert(100%) hue-rotate(180deg) brightness(1.5);
        }
        /* Kereső stílus */
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
        /* Hangerő csúszka stílus */
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
        .volume-slider::-webkit-slider-thumb:hover {
            transform: scale(1.1);
            box-shadow: 0 0 15px var(--primary);
        }

        /* Idővonal (Progress) csúszka stílus */
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
        .progress-slider::-webkit-slider-thumb:hover {
            transform: scale(1.2);
            box-shadow: 0 0 25px var(--secondary);
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
            padding: 5px 10px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 0.8em;
            transition: all 0.2s;
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
        /* Overlay & Loader */
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
    </style>
</head>
<body>
    <div id="overlay">
        <div class="spinner"></div>
        <div id="overlay-msg" style="font-family: 'Orbitron', sans-serif; color: var(--primary);">
            Kapcsolódás a telefonhoz...
        </div>
        <div style="font-size: 0.8em; color: #666; margin-top: 10px;">
            Győződj meg róla, hogy a telefonon a Zene mód van kiválasztva.
        </div>
    </div>
    <h1>Radiont Remote</h1>
    <div class="container">
        <!-- Most szól (Streaming) -->
        <div class="player-card">
            <div id="current-info" style="font-size: 0.9em; margin-bottom: 5px; opacity: 0.8;">Most szól itt (Böngésző):</div>
            <div id="current-title" style="font-weight: bold; margin-bottom: 10px;">-</div>
            <audio id="audio-player" controls></audio>
        </div>

        <!-- Távirányító + Most szól a telefonon -->
        <div class="player-card">
            <div style="font-weight: bold; margin-bottom: 15px;">Telefon távirányító</div>
            
            <div id="phone-now-playing" style="font-size: 0.9em; margin-bottom: 15px; color: var(--primary); text-align: center; min-height: 40px; display: flex; flex-direction: column; justify-content: center;">
                <span style="opacity: 0.5;">Betöltés...</span>
            </div>

            <!-- Idővonal -->
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
                <button class="btn btn-remote" id="remote-toggle-btn" onclick="remoteAction('toggle')">⏯ Play/Pause</button>
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

        <div class="search-container">
            <svg class="search-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
            <input type="text" id="search-input" class="search-input" placeholder="Keresés zenék vagy előadók között..." oninput="handleSearch(this.value)">
        </div>

        <div id="status" style="margin-top: 10px; margin-bottom: 10px; font-size: 0.9em; opacity: 0.8;">Dalok betöltése...</div>
        <ul class="song-list" id="list"></ul>
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

        let allSongs = [];
        let isUserAdjustingVolume = false;
        let isUserSeeking = false;

        function formatTime(ms) {
            if (!ms || isNaN(ms)) return '0:00';
            const totalSeconds = Math.floor(ms / 1000);
            const minutes = Math.floor(totalSeconds / 60);
            const seconds = totalSeconds % 60;
            return `\${minutes}:\${seconds.toString().padStart(2, '0')}`;
        }

        async function loadSongs() {
            try {
                const response = await fetch('/songs');
                allSongs = await response.json();
                renderSongs(allSongs);
            } catch (e) {
                status.innerText = 'Hiba a betöltéskor. Frissítsd az oldalt!';
            }
        }

        function renderSongs(songs) {
            status.innerText = `Összesen \${songs.length} dal találva`;
            list.innerHTML = '';
            
            if (songs.length === 0) {
                list.innerHTML = '<div style="text-align: center; padding: 40px; opacity: 0.5;">Nincs találat</div>';
                return;
            }

            songs.forEach(song => {
                const li = document.createElement('li');
                li.className = 'song-item';
                li.innerHTML = `
                    <div class="song-info" onclick="playHere(\${JSON.stringify(song).replace(/"/g, '&quot;')})">
                        <span class="song-title">\${song.title}</span>
                        <span class="song-artist">\${song.artist}</span>
                    </div>
                    <div class="actions">
                        <button class="btn btn-remote" onclick="playOnPhone(\${song.id})">Lejátszás a telefonon</button>
                    </div>
                `;
                list.appendChild(li);
            });
        }

        function handleSearch(query) {
            const filtered = allSongs.filter(song => 
                song.title.toLowerCase().includes(query.toLowerCase()) || 
                song.artist.toLowerCase().includes(query.toLowerCase())
            );
            renderSongs(filtered);
        }

        function playHere(song) {
            currentTitle.innerText = `\${song.artist} - \${song.title}`;
            audio.src = `/stream/\${song.id}`;
            audio.play();
        }

        async function playOnPhone(id) {
            try {
                await fetch(`/remote/play/\${id}`);
                checkStatus();
            } catch (e) {
                console.error('Hiba a vezérléskor.');
            }
        }

        async function remoteAction(action) {
            try {
                await fetch(`/remote/\${action}`);
                checkStatus();
            } catch (e) {
                console.error('Hiba a távirányításkor.');
            }
        }

        async function setVolume(val) {
            isUserAdjustingVolume = true;
            updateVolumeIcon(val);
            try {
                await fetch(`/remote/volume/\${val}`);
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
                await fetch(`/remote/seek/\${val}`);
            } catch (e) {
                console.error('Hiba a tekeréskor.');
            }
            setTimeout(() => { isUserSeeking = false; }, 1000);
        }


        loadSongs();

        // Státusz ellenőrzése
        const overlay = document.getElementById('overlay');
        const overlayMsg = document.getElementById('overlay-msg');
        let isReady = false;

        async function checkStatus() {
            try {
                const response = await fetch('/status');
                const data = await response.json();
                
                if (data.isReady) {
                    if (!isReady) {
                        overlay.style.display = 'none';
                        loadSongs();
                        isReady = true;
                    }

                    // Most szól a telefonon frissítése
                    if (data.nowPlaying) {
                        phoneNowPlaying.innerHTML = `
                            <span style="font-size: 0.8em; opacity: 0.7; margin-bottom: 2px;">Most szól a telefonon:</span>
                            <span style="font-weight: 600;">\${data.nowPlaying.title}</span>
                            <span style="font-size: 0.85em; opacity: 0.8;">\${data.nowPlaying.artist}</span>
                        `;
                        remoteToggleBtn.innerText = data.nowPlaying.isPlaying ? '⏸ Pause' : '▶ Play';
                        
                        // Idővonal frissítése
                        progressContainer.style.display = 'flex';
                        if (!isUserSeeking) {
                            progressSlider.max = data.duration;
                            progressSlider.value = data.position;
                            timeCurrent.innerText = formatTime(data.position);
                            timeTotal.innerText = formatTime(data.duration);
                        }
                    } else {
                        phoneNowPlaying.innerHTML = '<span style="opacity: 0.5;">A telefonon semmi nem szól.</span>';
                        remoteToggleBtn.innerText = '⏯ Play/Pause';
                        progressContainer.style.display = 'none';
                    }

                    // Hangerő frissítése
                    if (!isUserAdjustingVolume) {
                        volumeSlider.value = data.volume;
                        updateVolumeIcon(data.volume);
                    }
                } else {
                    overlay.style.display = 'flex';
                    isReady = false;
                    if (!data.isMusicMode) {
                        overlayMsg.innerText = 'Válts Zene módra a telefonon!';
                    } else if (data.isLoading) {
                        overlayMsg.innerText = 'Zenetár betöltése a telefonon...';
                    }
                }
            } catch (e) {
                overlay.style.display = 'flex';
                overlayMsg.innerText = 'Megszakadt a kapcsolat a telefonnal.';
                isReady = false;
            }
        }

        setInterval(checkStatus, 2000);
        checkStatus();

        // Gyors újracsatlakozás
        window.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                checkStatus();
            }
        });
        window.addEventListener('focus', checkStatus);
    </script>
</body>
</html>
''';
  }
}
