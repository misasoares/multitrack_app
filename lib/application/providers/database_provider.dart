import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models/song_model.dart';
import '../../domain/models/track_model.dart';

final isarProvider = FutureProvider<Isar>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  final isar = await Isar.open(
    [SongSchema, TrackSchema],
    directory: dir.path,
    inspector: false,
  );
  ref.onDispose(() {
    if (isar.isOpen) {
      // Ignorando o Future aqui é aceitável no ciclo de vida do provider.
      isar.close();
    }
  });
  return isar;
});