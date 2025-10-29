import 'dart:async';

import 'package:isar/isar.dart';

import '../../domain/models/song_model.dart';
import '../../domain/models/track_model.dart';

class SongRepository {
  final Isar isar;

  SongRepository(this.isar);

  Stream<Song?> watchSongWithTracks(int songId) {
    // Watch the song object reactively and load links each time
    return isar.songs
        .watchObject(songId, fireImmediately: true)
        .asyncMap((_) async {
      final song = await isar.songs.get(songId);
      if (song != null) {
        await song.tracks.load();
      }
      return song;
    });
  }

  Future<void> updateTrack(Track updatedTrack) async {
    await isar.writeTxn(() async {
      await isar.tracks.put(updatedTrack);
    });
  }

  Future<void> deleteSong(int songId) async {
    await isar.writeTxn(() async {
      final song = await isar.songs.get(songId);
      if (song != null) {
        await song.tracks.load();
        for (final track in song.tracks) {
          await isar.tracks.delete(track.id);
        }
        await isar.songs.delete(songId);
      }
    });
  }
}