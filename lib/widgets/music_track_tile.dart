import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/music_models.dart';
import '../theme.dart';

class MusicTrackTile extends StatelessWidget {
  final MusicTrack track;
  final VoidCallback onTap;
  final bool isPlaying;

  const MusicTrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.isPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isPlaying ? C.brand.withOpacity(0.1) : C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPlaying ? C.brand.withOpacity(0.3) : C.dim,
          ),
        ),
        child: Row(
          children: [
            // Album Art
            Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: track.albumArtUrl != null
                      ? Image.network(track.albumArtUrl!, width: 56, height: 56, fit: BoxFit.cover)
                      : Container(
                          width: 56, height: 56,
                          color: C.dim,
                          child: Icon(Icons.music_note, color: C.dim),
                        ),
                ),
                if (isPlaying)
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
                    child: Center(child: Icon(Icons.pause, color: C.brand)),
                  )
                else
                  Center(child: Icon(Icons.play_arrow, color: C.dim, size: 20)),
              ],
            ),
            const SizedBox(width: 16),
            
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    style: syne(sz: 15, w: FontWeight.bold, c: isPlaying ? C.brand : C.text),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.artistName,
                    style: dm(sz: 13, c: C.sub),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            
            // Duration & Viral Count
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(track.formattedDuration, style: dm(sz: 12, c: C.dim)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.trending_up, size: 10, color: C.dim),
                    const SizedBox(width: 4),
                    Text('${track.usageCount}k', style: dm(sz: 10, c: C.dim)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


