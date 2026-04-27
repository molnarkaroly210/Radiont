import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:just_audio/just_audio.dart';
import '../providers/music_provider.dart';
import '../models/album_model.dart';
import 'song_context_menu.dart';

class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});
  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  bool _searchOpen = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final mp = context.read<MusicProvider>();
      if (!mp.hasPermission) mp.requestPermission();
    });
  }

  @override
  void dispose() { _searchController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final mp = context.watch<MusicProvider>();
    final theme = Theme.of(context);
    final displayed = mp.displayedSongs;

    if (mp.isLoading) return Center(child: CircularProgressIndicator(color: theme.primaryColor));

    if (!mp.hasPermission) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.folder_off_rounded, size: 80, color: theme.primaryColor.withValues(alpha: 0.5)),
      const SizedBox(height: 20),
      Text("Nincs engedély a fájlok olvasásához.", style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
      const SizedBox(height: 20),
      ElevatedButton(onPressed: () => mp.requestPermission(),
        style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, foregroundColor: theme.colorScheme.onPrimary),
        child: const Text("Engedély megadása")),
    ]));

    return Stack(children: [
      Column(children: [
        // === KERESŐSÁV + RENDEZÉS ===
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            Expanded(child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 42,
              child: _searchOpen ? TextField(
                controller: _searchController, autofocus: true,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: "Keresés...", prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () {
                    _searchController.clear(); mp.setSearchQuery('');
                    setState(() => _searchOpen = false);
                  }),
                  filled: true, fillColor: theme.colorScheme.surface.withValues(alpha: 0.15),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(21), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onChanged: (v) => mp.setSearchQuery(v),
              ) : GestureDetector(
                onTap: () => setState(() => _searchOpen = true),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(21)),
                  alignment: Alignment.centerLeft,
                  child: Row(children: [
                    Icon(Icons.search, size: 18, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                    const SizedBox(width: 8),
                    Text("Keresés...", style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
                  ]),
                ),
              ),
            )),
            const SizedBox(width: 8),
            // Rendezés popup
            PopupMenuButton<SortMode>(
              icon: Icon(Icons.sort, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onSelected: (mode) => mp.setSortMode(mode),
              itemBuilder: (_) => [
                _sortItem(SortMode.title, "Cím (A-Z)", Icons.sort_by_alpha, mp.sortMode),
                _sortItem(SortMode.artist, "Előadó", Icons.person, mp.sortMode),
                _sortItem(SortMode.dateAdded, "Hozzáadás", Icons.calendar_today, mp.sortMode),
                _sortItem(SortMode.duration, "Időtartam", Icons.timer, mp.sortMode),
                _sortItem(SortMode.playCount, "Lejátszások", Icons.bar_chart, mp.sortMode),
              ],
            ),
          ]),
        ),
        // === ALBUM CHIP SÁV ===
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              _albumChip(context, "Összes", null, mp, theme.primaryColor),
              _albumChip(context, "Nincs mappában", "uncategorized", mp, theme.primaryColor),
              if (mp.mostPlayedSongs.isNotEmpty)
                _albumChip(context, "⭐ Top 25", "most_played", mp, Colors.amber),
              ...mp.albums.map((a) => _albumChipCustom(context, a, mp)),
              // + gomb
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: ActionChip(
                  avatar: Icon(Icons.add, size: 16, color: theme.primaryColor),
                  label: const Text("Új"),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  onPressed: () => showCreateAlbumDialog(context, mp),
                ),
              ),
            ],
          ),
        ),
        // === ZENELISTA ===
        Expanded(
          child: displayed.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.music_note_rounded, size: 60, color: theme.primaryColor.withValues(alpha: 0.4)),
                const SizedBox(height: 12),
                Text(mp.searchQuery.isNotEmpty ? "Nincs találat" : "Nincsenek zenék",
                  style: theme.textTheme.titleMedium),
                if (mp.songs.isNotEmpty && mp.searchQuery.isEmpty) ...[
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: () => mp.fetchSongs(),
                    style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, foregroundColor: theme.colorScheme.onPrimary),
                    child: const Text("Frissítés")),
                ]
              ]))
            : _buildSongList(context, mp, displayed, theme),
        ),
        if (mp.currentSong != null) const MusicPlayerControls(),
      ]),
    ]);
  }

  Widget _buildSongList(BuildContext ctx, MusicProvider mp, List<SongModel> songs, ThemeData theme) {
    // Album módban drag & drop
    if (mp.selectedAlbumId != null && mp.selectedAlbumId != 'uncategorized' && mp.selectedAlbumId != 'most_played') {
      return ReorderableListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        itemCount: songs.length,
        onReorder: (old, nw) => mp.reorderSongInAlbum(mp.selectedAlbumId!, old, nw),
        itemBuilder: (_, i) => _SongTile(key: ValueKey(songs[i].id), song: songs[i], index: i, mp: mp),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      itemCount: songs.length,
      itemBuilder: (_, i) => _SongTile(song: songs[i], index: i, mp: mp),
    );
  }

  PopupMenuEntry<SortMode> _sortItem(SortMode mode, String label, IconData icon, SortMode current) {
    return PopupMenuItem(value: mode, child: Row(children: [
      Icon(icon, size: 18, color: mode == current ? Theme.of(context).primaryColor : null),
      const SizedBox(width: 10), Text(label),
      if (mode == current) ...[const Spacer(), Icon(Icons.check, size: 16, color: Theme.of(context).primaryColor)]
    ]));
  }

  Widget _albumChip(BuildContext ctx, String label, String? id, MusicProvider mp, Color color) {
    final selected = mp.selectedAlbumId == id;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontSize: 12, color: selected ? Colors.white : null)),
        selected: selected,
        selectedColor: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onSelected: (_) => mp.selectAlbum(id),
      ),
    );
  }

  Widget _albumChipCustom(BuildContext ctx, Album album, MusicProvider mp) {
    final selected = mp.selectedAlbumId == album.id;
    final color = HSVColor.fromAHSV(1, album.hue, 0.7, 0.9).toColor();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onLongPress: () => _showAlbumOptions(ctx, album, mp),
        child: ChoiceChip(
          label: Text(album.name, style: TextStyle(fontSize: 12, color: selected ? Colors.white : null)),
          selected: selected,
          selectedColor: color,
          avatar: selected ? null : CircleAvatar(radius: 8, backgroundColor: color.withValues(alpha: 0.4)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          onSelected: (_) => mp.selectAlbum(album.id),
        ),
      ),
    );
  }

  void _showAlbumOptions(BuildContext ctx, Album album, MusicProvider mp) {
    final theme = Theme.of(ctx);
    final color = HSVColor.fromAHSV(1, album.hue, 0.7, 0.9).toColor();
    showModalBottomSheet(context: ctx, backgroundColor: Colors.transparent, builder: (bCtx) {
      return Container(
        margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(28), border: Border.all(color: color.withValues(alpha: 0.4))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(album.name, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          ListTile(leading: const Icon(Icons.edit), title: const Text("Átnevezés"),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onTap: () { Navigator.pop(bCtx); _renameAlbum(ctx, album, mp); }),
          ListTile(leading: const Icon(Icons.color_lens), title: const Text("Szín módosítása"),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onTap: () { Navigator.pop(bCtx); _changeAlbumColor(ctx, album, mp); }),
          ListTile(leading: Icon(Icons.delete, color: Colors.red.shade300),
            title: Text("Törlés", style: TextStyle(color: Colors.red.shade300)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onTap: () { Navigator.pop(bCtx); mp.deleteAlbum(album.id); }),
        ]),
      );
    });
  }

  void _renameAlbum(BuildContext ctx, Album album, MusicProvider mp) {
    final c = TextEditingController(text: album.name);
    showDialog(context: ctx, builder: (dCtx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text("Átnevezés"),
      content: TextField(controller: c, decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
      actions: [
        TextButton(child: const Text("Mégse"), onPressed: () => Navigator.pop(dCtx)),
        ElevatedButton(child: const Text("Mentés"), onPressed: () {
          if (c.text.trim().isNotEmpty) { mp.renameAlbum(album.id, c.text.trim()); Navigator.pop(dCtx); }
        }),
      ],
    ));
  }

  void _changeAlbumColor(BuildContext ctx, Album album, MusicProvider mp) {
    double hue = album.hue;
    showDialog(context: ctx, builder: (dCtx) => StatefulBuilder(builder: (dCtx, setSt) {
      final color = HSVColor.fromAHSV(1, hue, 0.7, 0.9).toColor();
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text("Szín módosítása"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(height: 30, decoration: BoxDecoration(borderRadius: BorderRadius.circular(15),
            gradient: const LinearGradient(colors: [
              Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00),
              Color(0xFF00FFFF), Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000)]))),
          Slider(value: hue, min: 0, max: 360, divisions: 360, activeColor: color,
            onChanged: (v) => setSt(() => hue = v)),
          CircleAvatar(radius: 24, backgroundColor: color),
        ]),
        actions: [
          TextButton(child: const Text("Mégse"), onPressed: () => Navigator.pop(dCtx)),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: color),
            child: const Text("Mentés"), onPressed: () { mp.setAlbumColor(album.id, hue); Navigator.pop(dCtx); }),
        ],
      );
    }));
  }
}

// === ZENE ELEM ===
class _SongTile extends StatelessWidget {
  final SongModel song; final int index; final MusicProvider mp;
  const _SongTile({super.key, required this.song, required this.index, required this.mp});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Song ID alapján ellenőrizzük, nem index alapján
    final isCurrent = mp.currentPlayingSongId == song.id;
    final isPlaying = isCurrent && mp.audioPlayer.playing;
    final playCount = mp.getPlayCount(song.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
      decoration: BoxDecoration(
        color: isCurrent ? theme.primaryColor.withValues(alpha: 0.15) : theme.colorScheme.surface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isCurrent ? theme.primaryColor.withValues(alpha: 0.3) : theme.colorScheme.onSurface.withValues(alpha: 0.05)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
        leading: ClipRRect(borderRadius: BorderRadius.circular(10),
          child: QueryArtworkWidget(id: song.id, type: ArtworkType.AUDIO,
            nullArtworkWidget: Container(width: 50, height: 50,
              decoration: BoxDecoration(color: theme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.music_note, color: theme.primaryColor)))),
        title: Text(song.title, style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          color: isCurrent ? theme.primaryColor : null), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Row(children: [
          Expanded(child: Text(song.artist ?? "Ismeretlen Előadó", style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7)), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (playCount > 0) Text("▶$playCount", style: TextStyle(fontSize: 10, color: theme.primaryColor.withValues(alpha: 0.6))),
        ]),
        trailing: isPlaying
          ? LoadingAnimationWidget.beat(color: theme.primaryColor, size: 20)
          : (isCurrent ? Icon(Icons.pause_circle_outline, color: theme.primaryColor, size: 24) : null),
        onTap: () {
          if (mp.currentPlayingSongId != song.id) {
            mp.playSong(index);
          } else {
            mp.togglePlayPause();
          }
        },
        onLongPress: () => showSongContextMenu(context, song),
      ),
    );
  }
}

// === LEJÁTSZÓ VEZÉRLŐK ===
class MusicPlayerControls extends StatelessWidget {
  const MusicPlayerControls({super.key});
  @override
  Widget build(BuildContext context) {
    final mp = context.watch<MusicProvider>();
    final theme = Theme.of(context);
    final song = mp.currentSong;
    if (song == null) return const SizedBox.shrink();

    return GlassmorphicContainer(
      width: double.infinity, height: 220, margin: const EdgeInsets.all(16),
      borderRadius: 30, blur: 20, border: 1.5,
      linearGradient: LinearGradient(colors: [
        theme.colorScheme.surface.withValues(alpha: 0.15), theme.colorScheme.surface.withValues(alpha: 0.05)],
        begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderGradient: LinearGradient(colors: [
        theme.primaryColor.withValues(alpha: 0.5), theme.colorScheme.surface.withValues(alpha: 0.1)],
        begin: Alignment.topLeft, end: Alignment.bottomRight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          // Zene infó
          Row(children: [
            QueryArtworkWidget(id: song.id, type: ArtworkType.AUDIO, size: 55,
              nullArtworkWidget: Container(width: 50, height: 50,
                decoration: BoxDecoration(color: theme.primaryColor.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.music_note, color: theme.primaryColor))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(song.artist ?? "Ismeretlen Előadó", style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
          ]),
          const SizedBox(height: 8),
          // Seek bar
          StreamBuilder<Duration>(
            stream: mp.audioPlayer.positionStream,
            builder: (ctx, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = mp.audioPlayer.duration ?? Duration(milliseconds: song.duration ?? 0);
              String fmt(Duration d) => "${d.inMinutes.remainder(60).toString().padLeft(2,'0')}:${d.inSeconds.remainder(60).toString().padLeft(2,'0')}";
              return Column(children: [
                SliderTheme(data: SliderTheme.of(ctx).copyWith(trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12)),
                  child: Slider(min: 0, max: dur.inMilliseconds.toDouble() > 0 ? dur.inMilliseconds.toDouble() : 1,
                    value: pos.inMilliseconds.toDouble().clamp(0, dur.inMilliseconds.toDouble()),
                    onChanged: (v) => mp.seek(Duration(milliseconds: v.toInt())),
                    activeColor: theme.primaryColor, inactiveColor: theme.colorScheme.onSurface.withValues(alpha: 0.2))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(fmt(pos), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
                    if (mp.isSleepTimerActive) Text("🌙 ${mp.sleepTimerRemaining!.inMinutes}:${(mp.sleepTimerRemaining!.inSeconds % 60).toString().padLeft(2,'0')}",
                      style: TextStyle(fontSize: 10, color: theme.primaryColor)),
                    Text(fmt(dur), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
                  ]),
                ),
              ]);
            },
          ),
          const SizedBox(height: 4),
          // Gombok – FittedBox megakadályozza a kilógást
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _ControlBtn(
                icon: mp.isSleepTimerActive ? Icons.nightlight_round : Icons.nightlight_outlined,
                color: mp.isSleepTimerActive ? theme.primaryColor : theme.iconTheme.color?.withValues(alpha: 0.5),
                size: 20, onTap: () => _showSleepTimer(context, mp)),
              const SizedBox(width: 6),
              _ControlBtn(
                icon: mp.isShuffleModeEnabled ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
                color: mp.isShuffleModeEnabled ? theme.primaryColor : theme.iconTheme.color?.withValues(alpha: 0.5),
                size: 20, onTap: mp.toggleShuffle),
              const SizedBox(width: 6),
              _ControlBtn(icon: Icons.skip_previous_rounded, color: theme.iconTheme.color?.withValues(alpha: 0.8), size: 28, onTap: mp.previousSong),
              const SizedBox(width: 8),
              GestureDetector(onTap: mp.togglePlayPause, child: Container(width: 48, height: 48,
                decoration: BoxDecoration(color: theme.primaryColor, shape: BoxShape.circle),
                child: Icon(mp.audioPlayer.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: theme.colorScheme.onPrimary, size: 28))),
              const SizedBox(width: 8),
              _ControlBtn(icon: Icons.skip_next_rounded, color: theme.iconTheme.color?.withValues(alpha: 0.8), size: 28, onTap: mp.nextSong),
              const SizedBox(width: 6),
              _ControlBtn(
                icon: mp.loopMode == LoopMode.off ? Icons.repeat_rounded : (mp.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_on_rounded),
                color: mp.loopMode != LoopMode.off ? theme.primaryColor : theme.iconTheme.color?.withValues(alpha: 0.5),
                size: 20, onTap: mp.toggleRepeat),
              const SizedBox(width: 6),
              _ControlBtn(icon: Icons.queue_music_rounded, color: theme.iconTheme.color?.withValues(alpha: 0.5), size: 20,
                onTap: () => _showQueue(context, mp)),
            ]),
          ),
        ]),
      ),
    );
  }

  void _showSleepTimer(BuildContext ctx, MusicProvider mp) {
    final theme = Theme.of(ctx);
    showModalBottomSheet(context: ctx, backgroundColor: Colors.transparent, builder: (bCtx) {
      return Container(
        margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(28)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text("Alvásidőzítő", style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          if (mp.isSleepTimerActive) ...[
            Text("Hátralévő: ${mp.sleepTimerRemaining!.inMinutes} perc", style: theme.textTheme.bodyLarge),
            const SizedBox(height: 12),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text("Kikapcsolás"), onPressed: () { mp.cancelSleepTimer(); Navigator.pop(bCtx); }),
          ] else ...[
            for (final mins in [15, 30, 60, 90])
              ListTile(title: Text("$mins perc"), leading: const Icon(Icons.timer),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () { mp.setSleepTimer(Duration(minutes: mins)); Navigator.pop(bCtx); }),
          ],
        ]),
      );
    });
  }

  void _showQueue(BuildContext ctx, MusicProvider mp) {
    final theme = Theme.of(ctx);
    showModalBottomSheet(
      context: ctx, backgroundColor: Colors.transparent, isScrollControlled: true,
      builder: (bCtx) {
        return StatefulBuilder(builder: (bCtx, setSt) {
          final queueSongs = mp.queue;
          return Container(
            margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(16),
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.65),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(28)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Header
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text("Lejátszási sor", style: theme.textTheme.titleLarge),
                Text("${queueSongs.length} zene", style: theme.textTheme.bodySmall),
              ]),
              const SizedBox(height: 12),
              // Lista – ReorderableListView a drag & drop-hoz
              Flexible(
                child: queueSongs.isEmpty
                  ? Center(child: Padding(
                      padding: const EdgeInsets.all(30),
                      child: Text("Nincs zene a sorban", style: theme.textTheme.bodyMedium)))
                  : ReorderableListView.builder(
                      shrinkWrap: true,
                      itemCount: queueSongs.length,
                      onReorder: (oldIndex, newIndex) {
                        mp.reorderQueue(oldIndex, newIndex);
                        setSt(() {});
                      },
                      proxyDecorator: (child, index, animation) {
                        return Material(
                          color: Colors.transparent,
                          elevation: 4,
                          borderRadius: BorderRadius.circular(12),
                          child: child,
                        );
                      },
                      itemBuilder: (_, i) {
                        final s = queueSongs[i];
                        final isCurrent = mp.currentPlayingSongId == s.id;
                        return Container(
                          key: ValueKey(s.id),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: isCurrent ? theme.primaryColor.withValues(alpha: 0.12) : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: isCurrent
                              ? Icon(Icons.equalizer_rounded, color: theme.primaryColor, size: 20)
                              : Text("${i + 1}", style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
                            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                color: isCurrent ? theme.primaryColor : null,
                                fontSize: 14)),
                            subtitle: Text(s.artist ?? "", maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
                            trailing: ReorderableDragStartListener(
                              index: i,
                              child: Icon(Icons.drag_handle_rounded, size: 20,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                            ),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            onTap: () { mp.playSong(i); Navigator.pop(bCtx); },
                          ),
                        );
                      },
                    ),
              ),
              // Hozzáadás gomb
              const SizedBox(height: 8),
              TextButton.icon(
                icon: Icon(Icons.add_rounded, color: theme.primaryColor),
                label: Text("Zene hozzáadása", style: TextStyle(color: theme.primaryColor)),
                onPressed: () => _showAddToQueue(ctx, mp, bCtx, setSt),
              ),
            ]),
          );
        });
      },
    );
  }

  /// Zene kiválasztó a queue-hoz
  void _showAddToQueue(BuildContext ctx, MusicProvider mp, BuildContext queueCtx, StateSetter queueSetSt) {
    final theme = Theme.of(ctx);
    final allSongs = mp.displayedSongs;
    showModalBottomSheet(
      context: ctx, backgroundColor: Colors.transparent, isScrollControlled: true,
      builder: (bCtx) {
        return Container(
          margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.55),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(28)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text("Zene hozzáadása a sorhoz", style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Flexible(child: ListView.builder(
              shrinkWrap: true, itemCount: allSongs.length,
              itemBuilder: (_, i) {
                final s = allSongs[i];
                final inQueue = mp.queue.any((q) => q.id == s.id);
                return ListTile(
                  dense: true,
                  leading: Icon(inQueue ? Icons.check_circle : Icons.add_circle_outline,
                    color: inQueue ? theme.primaryColor : theme.colorScheme.onSurface.withValues(alpha: 0.4), size: 20),
                  title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(s.artist ?? "", style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  onTap: inQueue ? null : () {
                    mp.addToQueue(s);
                    queueSetSt(() {});
                    Navigator.pop(bCtx);
                  },
                );
              },
            )),
          ]),
        );
      },
    );
  }
}

/// Kompakt vezérlő gomb – nem használ IconButton-t (az alapértelmezett padding kilógást okoz)
class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final double size;
  final VoidCallback onTap;
  const _ControlBtn({required this.icon, this.color, required this.size, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: size, color: color),
      ),
    );
  }
}
