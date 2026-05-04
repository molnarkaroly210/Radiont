// lib/services/streaming_service.dart

import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
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

    if (path == 'songs') {
      final songs = musicProvider.songs.map((s) => {
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
        final index = musicProvider.songs.indexWhere((s) => s.id == id);
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

    // Fájl feltöltése és lejátszása a telefonon
    if (path == 'upload' && request.method == 'POST') {
      try {
        final body = await request.read().toList();
        final bytes = body.expand((x) => x).toList();
        
        final tempDir = await Directory.systemTemp.createTemp('radiont_upload');
        final file = File('${tempDir.path}/uploaded_song.mp3');
        await file.writeAsBytes(bytes);
        
        // Lejátszás a telefonon
        musicProvider.audioPlayer.setAudioSource(AudioSource.uri(Uri.file(file.path), 
          tag: const MediaItem(id: 'uploaded', title: 'Feltöltött zene', artist: 'Távoli eszközről')));
        musicProvider.audioPlayer.play();
        
        return Response.ok('Sikeres feltöltés és lejátszás.');
      } catch (e) {
        return Response.internalServerError(body: 'Hiba a feltöltéskor: $e');
      }
    }

    if (path.startsWith('stream/')) {
      final idStr = path.replaceFirst('stream/', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        final song = musicProvider.songs.where((s) => s.id == id).firstOrNull;
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
        .upload-section {
            margin-top: 20px;
            padding: 15px;
            background: rgba(255,255,255,0.03);
            border-radius: 12px;
            width: 100%;
            text-align: center;
        }
        #current-title {
            font-weight: bold;
            color: var(--primary);
        }
    </style>
</head>
<body>
    <h1>Radiont Remote</h1>
    <div class="container">
        <div class="player-card">
            <div id="current-info">Most szól itt (Streaming): <span id="current-title">-</span></div>
            <audio id="audio-player" controls></audio>
        </div>

        <div class="player-card">
            <div style="font-weight: bold; margin-bottom: 15px;">Telefon távirányító</div>
            <div class="actions">
                <button class="btn" onclick="remoteAction('prev')">⏮ Előző</button>
                <button class="btn btn-remote" onclick="remoteAction('toggle')">⏯ Play/Pause</button>
                <button class="btn" onclick="remoteAction('next')">⏭ Következő</button>
            </div>
        </div>

        <div class="upload-section">
            <label for="file-upload" class="btn" style="display: inline-block;">Saját zene küldése a telefonra</label>
            <input type="file" id="file-upload" style="display: none;" accept="audio/*">
            <div id="upload-status" style="font-size: 0.8em; margin-top: 5px; color: #888;"></div>
        </div>

        <div id="status" style="margin-top: 20px;">Dalok betöltése...</div>
        <ul class="song-list" id="list"></ul>
    </div>

    <script>
        const audio = document.getElementById('audio-player');
        const list = document.getElementById('list');
        const currentTitle = document.getElementById('current-title');
        const status = document.getElementById('status');
        const fileUpload = document.getElementById('file-upload');
        const uploadStatus = document.getElementById('upload-status');

        async function loadSongs() {
            try {
                const response = await fetch('/songs');
                const songs = await response.json();
                status.innerText = `Összesen \${songs.length} dal érhető a telefonon`;
                
                list.innerHTML = '';
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
            } catch (e) {
                status.innerText = 'Hiba a betöltéskor. Frissítsd az oldalt!';
            }
        }

        function playHere(song) {
            currentTitle.innerText = `\${song.artist} - \${song.title}`;
            audio.src = `/stream/\${song.id}`;
            audio.play();
        }

        async function playOnPhone(id) {
            try {
                await fetch(`/remote/play/\${id}`);
            } catch (e) {
                console.error('Hiba a vezérléskor.');
            }
        }

        async function remoteAction(action) {
            try {
                await fetch(`/remote/\${action}`);
            } catch (e) {
                console.error('Hiba a távirányításkor.');
            }
        }

        fileUpload.onchange = async (e) => {
            const file = e.target.files[0];
            if (!file) return;

            uploadStatus.innerText = 'Feltöltés és lejátszás indítása...';
            try {
                const response = await fetch('/upload', {
                    method: 'POST',
                    body: file
                });
                if (response.ok) {
                    uploadStatus.innerText = 'Sikeresen elküldve a telefonra!';
                } else {
                    uploadStatus.innerText = 'Hiba a küldés során.';
                }
            } catch (err) {
                uploadStatus.innerText = 'Hiba történt.';
            }
        };

        loadSongs();
    </script>
</body>
</html>
''';
  }
}
