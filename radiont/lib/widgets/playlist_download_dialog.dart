import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/music_provider.dart';

class PlaylistDownloadDialog extends StatefulWidget {
  final String url;
  const PlaylistDownloadDialog({super.key, required this.url});

  @override
  State<PlaylistDownloadDialog> createState() => _PlaylistDownloadDialogState();
}

class _PlaylistDownloadDialogState extends State<PlaylistDownloadDialog> {
  bool _isStarted = false;
  int _current = 0;
  int _total = 0;
  String _currentTitle = "Adatok lekérése...";
  double _progress = 0;
  String _error = "";
  bool _isDone = false;

  void _startDownload() {
    setState(() {
      _isStarted = true;
    });

    context.read<MusicProvider>().downloadYoutubePlaylist(
      widget.url,
      onSongStart: (current, total, title) {
        if (mounted) {
          setState(() {
            _current = current;
            _total = total;
            _currentTitle = title;
            _progress = 0;
          });
        }
      },
      onSongProgress: (progress) {
        if (mounted) {
          setState(() {
            _progress = progress;
          });
        }
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _isDone = true;
          });
        }
      },
      onError: (err) {
        if (mounted) {
          setState(() {
            _error = err;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget content;
    String titleText = "Lejátszási lista";

    if (!_isStarted) {
      titleText = "Letöltés indítása";
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.playlist_add_check_rounded, size: 48, color: Colors.blue),
          const SizedBox(height: 16),
          const Text(
            "Lejátszási lista/album észlelve.",
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            "Szeretnéd az összes zenét letölteni ebből a listából?",
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Mégse"),
              ),
              ElevatedButton(
                onPressed: _startDownload,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text("Letöltés indítása"),
              ),
            ],
          ),
        ],
      );
    } else if (_error.isNotEmpty) {
      titleText = "Hiba történt";
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text(_error, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Bezárás"),
          ),
        ],
      );
    } else if (_isDone) {
      titleText = "Sikeres letöltés";
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: Colors.green),
          const SizedBox(height: 16),
          const Text("A lejátszási lista összes eleme letöltve!", textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Nagyszerű"),
          ),
        ],
      );
    } else {
      titleText = "Letöltés: $_current / $_total";
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _currentTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              minHeight: 8,
              backgroundColor: theme.primaryColor.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(theme.primaryColor),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "${(_progress * 100).toStringAsFixed(0)}%",
            style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            "Kérlek ne zárd be az alkalmazást...",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      );
    }

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1A1A2E) : Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: theme.primaryColor.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 20,
                offset: const Offset(0, 10),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                titleText,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              content,
            ],
          ),
        ),
      ),
    );
  }
}
