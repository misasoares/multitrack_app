import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import '../../domain/models/song_model.dart';
import '../../domain/models/track_model.dart';
import 'database_provider.dart';

// Provider para listar todas as músicas
final songsListProvider = FutureProvider<List<Song>>((ref) async {
  final isar = await ref.watch(isarProvider.future);
  return await isar.songs.where().findAll();
});

// Provider para obter uma música específica com suas faixas
final songWithTracksProvider = FutureProvider.family<Song?, int>((ref, songId) async {
  final isar = await ref.watch(isarProvider.future);
  final song = await isar.songs.get(songId);
  if (song != null) {
    await song.tracks.load();
  }
  return song;
});

// Provider para salvar uma música
final songServiceProvider = Provider<SongService>((ref) {
  return SongService(ref);
});

class SongService {
  final Ref _ref;
  
  SongService(this._ref);

  Future<void> updateSongName(int songId, String newName) async {
    final isar = await _ref.read(isarProvider.future);
    await isar.writeTxn(() async {
      final song = await isar.songs.get(songId);
      if (song != null) {
        song.name = newName;
        await isar.songs.put(song);
      }
    });
    // Invalida o cache para atualizar a UI
    _ref.invalidate(songsListProvider);
    _ref.invalidate(songWithTracksProvider(songId));
  }

  Future<void> updateTrackName(int trackId, String newName) async {
    final isar = await _ref.read(isarProvider.future);
    await isar.writeTxn(() async {
      final track = await isar.tracks.get(trackId);
      if (track != null) {
        track.name = newName;
        await isar.tracks.put(track);
      }
    });
    // Invalida todos os providers relacionados
    _ref.invalidate(songsListProvider);
  }

  Future<void> deleteSong(int songId) async {
    final isar = await _ref.read(isarProvider.future);
    await isar.writeTxn(() async {
      final song = await isar.songs.get(songId);
      if (song != null) {
        // Remove todas as faixas associadas
        await song.tracks.load();
        for (final track in song.tracks) {
          await isar.tracks.delete(track.id);
        }
        // Remove a música
        await isar.songs.delete(songId);
      }
    });
    _ref.invalidate(songsListProvider);
  }
}