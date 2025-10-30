import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import '../../domain/models/endpoint_model.dart';
import '../providers/database_provider.dart';
import '../../infrastructure/database/endpoint_repository.dart';

// Provider do repositório Endpoint baseado no Isar
final endpointRepositoryProvider = Provider<EndpointRepository>((ref) {
  final isar = ref.watch(isarProvider).maybeWhen(
        data: (db) => db,
        orElse: () => null,
      ) ??
      (throw StateError('Isar database is not ready'));
  return EndpointRepository(isar);
});

// StreamProvider.family para observar endpoints de uma música, ordenados por tempo
final endpointsBySongProvider = StreamProvider.autoDispose
    .family<List<Endpoint>, int>((ref, songId) {
  final isarFuture = ref.watch(isarProvider.future);
  return isarFuture.asStream().asyncExpand((isar) {
    final repo = EndpointRepository(isar);
    return repo.watchBySong(songId);
  });
});

// Serviço simples para operações com validação (pode ser expandido futuramente)
final endpointServiceProvider = Provider<EndpointService>((ref) {
  return EndpointService(ref);
});

class EndpointService {
  final Ref _ref;

  EndpointService(this._ref);

  Future<Endpoint> create({
    required int songId,
    required int timeMs,
    String? label,
    String? colorHex,
  }) async {
    final isar = await _ref.read(isarProvider.future);
    final repo = EndpointRepository(isar);
    final created = await repo.create(
      songId: songId,
      timeMs: timeMs,
      label: label,
      colorHex: colorHex,
    );
    // Invalida streams relacionadas
    _ref.invalidate(endpointsBySongProvider(songId));
    return created;
  }

  Future<void> updateLabel(int endpointId, String newLabel, int songId) async {
    final isar = await _ref.read(isarProvider.future);
    final repo = EndpointRepository(isar);
    await repo.updateLabel(endpointId, newLabel);
    _ref.invalidate(endpointsBySongProvider(songId));
  }

  Future<void> updateColor(int endpointId, String colorHex, int songId) async {
    final isar = await _ref.read(isarProvider.future);
    final repo = EndpointRepository(isar);
    await repo.updateColor(endpointId, colorHex);
    _ref.invalidate(endpointsBySongProvider(songId));
  }

  Future<void> updateTimeMs(int endpointId, int newTimeMs, int songId) async {
    final isar = await _ref.read(isarProvider.future);
    final repo = EndpointRepository(isar);
    await repo.updateTimeMs(endpointId, newTimeMs);
    _ref.invalidate(endpointsBySongProvider(songId));
  }

  Future<Endpoint?> delete(int endpointId, int songId) async {
    final isar = await _ref.read(isarProvider.future);
    final repo = EndpointRepository(isar);
    final deleted = await repo.delete(endpointId);
    _ref.invalidate(endpointsBySongProvider(songId));
    return deleted;
  }

  Future<void> restore(Endpoint endpoint) async {
    final isar = await _ref.read(isarProvider.future);
    final repo = EndpointRepository(isar);
    await repo.restore(endpoint);
    _ref.invalidate(endpointsBySongProvider(endpoint.songId));
  }
}