import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:just_audio/just_audio.dart';
import '../providers/music_provider.dart';

class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  @override
  void initState() {
    super.initState();
    // Kérjük az engedélyeket és töltsük be a zenéket, amikor a képernyő megnyílik
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final musicProvider = context.read<MusicProvider>();
      if (!musicProvider.hasPermission) {
        musicProvider.requestPermission();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final musicProvider = context.watch<MusicProvider>();
    final theme = Theme.of(context);

    if (musicProvider.isLoading) {
      return Center(
        child: CircularProgressIndicator(color: theme.primaryColor),
      );
    }

    if (!musicProvider.hasPermission) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_off_rounded, size: 80, color: theme.primaryColor.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text(
              "Nincs engedély a helyi fájlok olvasásához.",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => musicProvider.requestPermission(),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: theme.colorScheme.onPrimary,
              ),
              child: const Text("Engedély megadása"),
            ),
          ],
        ),
      );
    }

    if (musicProvider.songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_note_rounded, size: 80, color: theme.primaryColor.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text(
              "Nincsenek helyi zenék a telefonodon.",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => musicProvider.fetchSongs(),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: theme.colorScheme.onPrimary,
              ),
              child: const Text("Frissítés"),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            itemCount: musicProvider.songs.length,
            itemBuilder: (context, index) {
              final song = musicProvider.songs[index];
              final isPlaying = musicProvider.currentIndex == index && musicProvider.audioPlayer.playing;
              final isCurrent = musicProvider.currentIndex == index;

              return Container(
                margin: const EdgeInsets.only(bottom: 10, left: 5, right: 5),
                decoration: BoxDecoration(
                  color: isCurrent 
                    ? theme.primaryColor.withValues(alpha: 0.15) 
                    : theme.colorScheme.surface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isCurrent 
                      ? theme.primaryColor.withValues(alpha: 0.3) 
                      : theme.colorScheme.onSurface.withValues(alpha: 0.05)
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: QueryArtworkWidget(
                      id: song.id,
                      type: ArtworkType.AUDIO,
                      nullArtworkWidget: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.music_note, color: theme.primaryColor),
                      ),
                    ),
                  ),
                  title: Text(
                    song.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      color: isCurrent ? theme.primaryColor : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    song.artist ?? "Ismeretlen Előadó",
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isPlaying
                      ? LoadingAnimationWidget.beat(color: theme.primaryColor, size: 20)
                      : (isCurrent ? Icon(Icons.play_circle_outline, color: theme.primaryColor, size: 24) : null),
                  onTap: () {
                    if (musicProvider.currentIndex != index) {
                      musicProvider.playSong(index);
                    } else {
                      musicProvider.togglePlayPause();
                    }
                  },
                ),
              );
            },
          ),
        ),
        // Mini player vagy teljes lejátszó sáv a lista alján
        if (musicProvider.currentSong != null)
          const MusicPlayerControls(),
      ],
    );
  }
}

class MusicPlayerControls extends StatelessWidget {
  const MusicPlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    final musicProvider = context.watch<MusicProvider>();
    final theme = Theme.of(context);
    final song = musicProvider.currentSong;

    if (song == null) return const SizedBox.shrink();

    return GlassmorphicContainer(
      width: double.infinity,
      height: 200, // Kicsit növeljük a magasságot az overflow elkerülése végett
      margin: const EdgeInsets.all(20),
      borderRadius: 30,
      blur: 20,
      border: 1.5,
      linearGradient: LinearGradient(
        colors: [
          theme.colorScheme.surface.withValues(alpha: 0.15),
          theme.colorScheme.surface.withValues(alpha: 0.05)
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderGradient: LinearGradient(
        colors: [
          theme.primaryColor.withValues(alpha: 0.5),
          theme.colorScheme.surface.withValues(alpha: 0.1)
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                QueryArtworkWidget(
                  id: song.id,
                  type: ArtworkType.AUDIO,
                  size: 60,
                  nullArtworkWidget: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.music_note, color: theme.primaryColor),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        song.artist ?? "Ismeretlen Előadó",
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Csúszka (Seek Bar)
            StreamBuilder<Duration>(
              stream: musicProvider.audioPlayer.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = musicProvider.audioPlayer.duration ?? Duration(milliseconds: song.duration ?? 0);
                
                String formatDuration(Duration d) {
                  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
                  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
                  return "$minutes:$seconds";
                }

                return Column(
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      ),
                      child: Slider(
                        min: 0.0,
                        max: duration.inMilliseconds.toDouble() > 0 ? duration.inMilliseconds.toDouble() : 1.0,
                        value: position.inMilliseconds.toDouble().clamp(0.0, duration.inMilliseconds.toDouble()),
                        onChanged: (value) {
                          musicProvider.seek(Duration(milliseconds: value.toInt()));
                        },
                        activeColor: theme.primaryColor,
                        inactiveColor: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(formatDuration(position), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
                        Text(formatDuration(duration), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
                      ],
                    ),
                  ],
                );
              },
            ),
            // Gombok
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(
                    musicProvider.isShuffleModeEnabled ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
                    color: musicProvider.isShuffleModeEnabled ? theme.primaryColor : theme.iconTheme.color?.withValues(alpha: 0.5),
                  ),
                  onPressed: musicProvider.toggleShuffle,
                  iconSize: 22,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: musicProvider.previousSong,
                  iconSize: 32,
                  color: theme.iconTheme.color?.withValues(alpha: 0.8),
                ),
                GestureDetector(
                  onTap: musicProvider.togglePlayPause,
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: theme.primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      musicProvider.audioPlayer.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: theme.colorScheme.onPrimary,
                      size: 32,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: musicProvider.nextSong,
                  iconSize: 32,
                  color: theme.iconTheme.color?.withValues(alpha: 0.8),
                ),
                IconButton(
                  icon: Icon(
                    musicProvider.loopMode == LoopMode.off ? Icons.repeat_rounded : (musicProvider.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_on_rounded),
                    color: musicProvider.loopMode != LoopMode.off ? theme.primaryColor : theme.iconTheme.color?.withValues(alpha: 0.5),
                  ),
                  onPressed: musicProvider.toggleRepeat,
                  iconSize: 22,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
