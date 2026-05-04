import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/music_provider.dart';

class SingleDownloadDialog extends StatefulWidget {
  final String url;
  const SingleDownloadDialog({super.key, required this.url});

  @override
  State<SingleDownloadDialog> createState() => _SingleDownloadDialogState();
}

class _SingleDownloadDialogState extends State<SingleDownloadDialog> {
  bool _isStarted = false;
  String _status = "Adatok lekérése...";
  double _progress = 0;
  String _error = "";
  bool _isDone = false;
  String _fileName = "";

  void _startDownload() {
    setState(() {
      _isStarted = true;
    });

    context.read<MusicProvider>().downloadYoutubeVideo(
      widget.url,
      onProgress: (progress, status) {
        if (mounted) {
          setState(() {
            _progress = progress;
            _status = status;
          });
        }
      },
      onDone: (fileName) {
        if (mounted) {
          setState(() {
            _isDone = true;
            _fileName = fileName;
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
    String titleText = "Zene letöltése";

    if (!_isStarted) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download_for_offline_rounded, size: 48, color: Colors.blue),
          const SizedBox(height: 16),
          const Text("Szeretnéd letölteni ezt a zenét?"),
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
                child: const Text("Letöltés"),
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
      titleText = "Sikeres mentés";
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: Colors.green),
          const SizedBox(height: 16),
          Text("Mentve: $_fileName", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Nagyszerű"),
          ),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_status, style: const TextStyle(fontWeight: FontWeight.w500)),
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
