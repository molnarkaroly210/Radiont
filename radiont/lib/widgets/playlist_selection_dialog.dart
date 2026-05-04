import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../providers/music_provider.dart';

class PlaylistSelectionDialog extends StatefulWidget {
  final List<Video> videos;
  final String playlistTitle;

  const PlaylistSelectionDialog({
    super.key,
    required this.videos,
    required this.playlistTitle,
  });

  @override
  State<PlaylistSelectionDialog> createState() => _PlaylistSelectionDialogState();
}

class _PlaylistSelectionDialogState extends State<PlaylistSelectionDialog> {
  late List<bool> _selected;
  bool _selectAll = true;

  @override
  void initState() {
    super.initState();
    final provider = context.read<MusicProvider>();
    // Automatikusan kivesszük a pipát azokról, amik már megvannak
    _selected = widget.videos.map((v) => !provider.isDuplicate(v.title)).toList();
    _selectAll = _selected.every((e) => e);
  }

  void _toggleSelectAll(bool? val) {
    setState(() {
      _selectAll = val ?? false;
      for (int i = 0; i < _selected.length; i++) {
        _selected[i] = _selectAll;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: double.maxFinite,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1A1A2E) : Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: theme.primaryColor.withValues(alpha: 0.2)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Text(
                      widget.playlistTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Válaszd ki a letölteni kívánt dalokat",
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              CheckboxListTile(
                title: const Text("Összes kijelölése", style: TextStyle(fontWeight: FontWeight.bold)),
                value: _selectAll,
                onChanged: _toggleSelectAll,
                activeColor: theme.primaryColor,
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: widget.videos.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.withValues(alpha: 0.1)),
                  itemBuilder: (context, index) {
                    final video = widget.videos[index];
                    final isDup = context.read<MusicProvider>().isDuplicate(video.title);

                    return CheckboxListTile(
                      title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(video.author, style: const TextStyle(fontSize: 12)),
                          if (isDup)
                            Text(
                              "Már a könyvtárban van",
                              style: TextStyle(
                                color: isDark ? Colors.orangeAccent : Colors.orange.shade800,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                        ],
                      ),
                      value: _selected[index],
                      activeColor: theme.primaryColor,
                      onChanged: (val) {
                        setState(() {
                          _selected[index] = val ?? false;
                          _selectAll = _selected.every((e) => e);
                        });
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Mégse"),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final selectedUrls = <String>[];
                        for (int i = 0; i < widget.videos.length; i++) {
                          if (_selected[i]) {
                            selectedUrls.add('https://www.youtube.com/watch?v=${widget.videos[i].id.value}');
                          }
                        }
                        Navigator.pop(context, selectedUrls);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text("${_selected.where((e) => e).length} letöltése"),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
