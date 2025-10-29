import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import '../../domain/models/song_model.dart';
import '../notifiers/add_song_notifier.dart';
import '../../infrastructure/database/song_repository.dart';
import 'database_provider.dart';

// Provides SongRepository instance using the Isar DB
final songRepositoryProvider = Provider<SongRepository>((ref) {
  final isar = ref.watch(isarProvider).maybeWhen(
    data: (db) => db,
    orElse: () => null,
  );
  if (isar == null) {
    // Fallback for early watch; replace later once isar resolves
    throw StateError('Isar database is not ready');
  }
  return SongRepository(isar);
});

// StreamProvider.family to watch a specific Song with its tracks
final currentSongProvider = StreamProvider.autoDispose.family<Song?, int>((ref, songId) {
  final isarFuture = ref.watch(isarProvider.future);
  return isarFuture.asStream().asyncExpand((isar) {
    final repository = SongRepository(isar);
    return repository.watchSongWithTracks(songId);
  });
});

// Provider para estado/ações de adicionar música (usado no AddSongScreen)
final addSongProvider = StateNotifierProvider<AddSongNotifier, AddSongState>((ref) {
  return AddSongNotifier();
});