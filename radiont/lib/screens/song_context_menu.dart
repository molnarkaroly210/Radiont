import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';
import '../providers/music_provider.dart';

void showSongContextMenu(BuildContext context, SongModel song) {
  final theme = Theme.of(context);
  final mp = context.read<MusicProvider>();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: theme.primaryColor.withValues(alpha: 0.3)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Header
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: QueryArtworkWidget(id: song.id, type: ArtworkType.AUDIO, size: 55,
                  nullArtworkWidget: Container(width: 55, height: 55,
                    decoration: BoxDecoration(color: theme.primaryColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                    child: Icon(Icons.music_note, color: theme.primaryColor))),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(song.title, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(song.artist ?? "Ismeretlen", style: theme.textTheme.bodySmall),
              ])),
            ]),
            const SizedBox(height: 16),
            Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
            // Albumhoz adás
            _MenuItem(icon: Icons.playlist_add_rounded, label: "Hozzáadás albumhoz", onTap: () {
              Navigator.pop(ctx);
              _showAlbumPicker(context, song, mp);
            }),
            // Következő lejátszása
            _MenuItem(icon: Icons.skip_next_rounded, label: "Következő lejátszása", onTap: () {
              mp.playNext(song);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text("\"${song.title}\" következőnek beállítva"), behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ));
            }),
            // Hozzáadás a lejátszási sorhoz
            _MenuItem(icon: Icons.queue_music_rounded, label: "Hozzáadás a lejátszási sorhoz", onTap: () {
              mp.addToQueue(song);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text("\"${song.title}\" hozzáadva a sorhoz"), behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ));
            }),
            // Archiválás
            _MenuItem(icon: Icons.archive_rounded, label: "Archiválás", onTap: () {
              mp.archiveSong(song.id);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text("${song.title} archiválva"), behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                action: SnackBarAction(label: "Visszavonás", onPressed: () => mp.unarchiveSong(song.id)),
              ));
            }),
            // Eltávolítás albumból (ha van kiválasztott album)
            if (mp.selectedAlbumId != null && mp.selectedAlbumId != 'uncategorized' && mp.selectedAlbumId != 'most_played')
              _MenuItem(icon: Icons.remove_circle_outline, label: "Eltávolítás ebből az albumból", onTap: () {
                mp.removeSongFromAlbum(mp.selectedAlbumId!, song.id);
                Navigator.pop(ctx);
              }),
            // Törlés
            _MenuItem(icon: Icons.delete_outline_rounded, label: "Törlés a telefonról", color: Colors.red.shade300, onTap: () {
              Navigator.pop(ctx);
              _confirmDelete(context, song, mp);
            }),
            // Részletek
            _MenuItem(icon: Icons.info_outline_rounded, label: "Részletek", onTap: () {
              Navigator.pop(ctx);
              _showDetails(context, song, mp);
            }),
          ]),
        ),
      );
    },
  );
}

class _MenuItem extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback onTap; final Color? color;
  const _MenuItem({required this.icon, required this.label, required this.onTap, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: c, size: 22), title: Text(label, style: TextStyle(color: c)),
      onTap: onTap, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }
}

void _showAlbumPicker(BuildContext context, SongModel song, MusicProvider mp) {
  final theme = Theme.of(context);
  showModalBottomSheet(
    context: context, backgroundColor: Colors.transparent, isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
      return Container(
        margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(28), border: Border.all(color: theme.primaryColor.withValues(alpha: 0.3))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text("Hozzáadás albumhoz", style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          if (mp.albums.isEmpty)
            Padding(padding: const EdgeInsets.all(20), child: Text("Nincs album. Hozz létre egyet!", style: theme.textTheme.bodyMedium)),
          ...mp.albums.map((album) {
            final inAlbum = mp.isSongInAlbum(album.id, song.id);
            final albumColor = HSVColor.fromAHSV(1, album.hue, 0.7, 0.9).toColor();
            return CheckboxListTile(
              value: inAlbum,
              title: Text(album.name),
              secondary: CircleAvatar(radius: 14, backgroundColor: albumColor.withValues(alpha: 0.3),
                child: Icon(Icons.album, size: 16, color: albumColor)),
              activeColor: albumColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onChanged: (v) {
                if (v == true) { mp.addSongToAlbum(album.id, song.id); }
                else { mp.removeSongFromAlbum(album.id, song.id); }
                setSt(() {});
              },
            );
          }),
          const SizedBox(height: 10),
          TextButton.icon(
            icon: Icon(Icons.add, color: theme.primaryColor),
            label: Text("Új album", style: TextStyle(color: theme.primaryColor)),
            onPressed: () { Navigator.pop(ctx); showCreateAlbumDialog(context, mp); },
          ),
        ]),
      );
    }),
  );
}

void showCreateAlbumDialog(BuildContext context, MusicProvider mp) {
  final theme = Theme.of(context);
  final controller = TextEditingController();
  double hue = 200;
  showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
    final color = HSVColor.fromAHSV(1, hue, 0.7, 0.9).toColor();
    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text("Új album"),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: controller, decoration: InputDecoration(hintText: "Album neve",
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
        const SizedBox(height: 20),
        Text("Szín", style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Container(height: 30, decoration: BoxDecoration(borderRadius: BorderRadius.circular(15),
          gradient: const LinearGradient(colors: [
            Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00),
            Color(0xFF00FFFF), Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000)]))),
        Slider(value: hue, min: 0, max: 360, divisions: 360, activeColor: color,
          onChanged: (v) => setSt(() => hue = v)),
        CircleAvatar(radius: 20, backgroundColor: color),
      ]),
      actions: [
        TextButton(child: const Text("Mégse"), onPressed: () => Navigator.pop(ctx)),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: color),
          child: const Text("Létrehozás"),
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              mp.createAlbum(controller.text.trim(), hue: hue);
              Navigator.pop(ctx);
            }
          }),
      ],
    );
  }));
}

void _confirmDelete(BuildContext context, SongModel song, MusicProvider mp) {
  showDialog(context: context, builder: (ctx) => AlertDialog(
    title: const Text("Zene törlése"),
    content: Text("Biztosan törölni akarod?\n\n${song.title}\n\nEz a fájl véglegesen törlődik a telefonról!"),
    actions: [
      TextButton(child: const Text("Mégse"), onPressed: () => Navigator.pop(ctx)),
      ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
        child: const Text("Törlés"),
        onPressed: () async {
          Navigator.pop(ctx);
          final ok = await mp.deleteSong(song);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(ok ? "Törölve: ${song.title}" : "Nem sikerült törölni"),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ));
          }
        }),
    ],
  ));
}

void _showDetails(BuildContext context, SongModel song, MusicProvider mp) {
  final dur = Duration(milliseconds: song.duration ?? 0);
  final mins = dur.inMinutes; final secs = dur.inSeconds % 60;
  showDialog(context: context, builder: (ctx) => AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    title: const Text("Részletek"),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      _DetailRow("Cím", song.title),
      _DetailRow("Előadó", song.artist ?? "Ismeretlen"),
      _DetailRow("Album", song.album ?? "Ismeretlen"),
      _DetailRow("Időtartam", "$mins:${secs.toString().padLeft(2, '0')}"),
      _DetailRow("Lejátszások", "${mp.getPlayCount(song.id)}×"),
    ]),
    actions: [TextButton(child: const Text("OK"), onPressed: () => Navigator.pop(ctx))],
  ));
}

class _DetailRow extends StatelessWidget {
  final String label, value;
  const _DetailRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      SizedBox(width: 90, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
      Expanded(child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis)),
    ]),
  );
}
