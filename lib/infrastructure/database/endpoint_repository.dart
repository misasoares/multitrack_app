import 'dart:async';

import 'package:isar/isar.dart';

import '../../domain/models/endpoint_model.dart';

class EndpointRepository {
  final Isar isar;

  EndpointRepository(this.isar);

  // Observa endpoints de uma música, sempre ordenados por timeMs asc
  Stream<List<Endpoint>> watchBySong(int songId) {
    return isar.endpoints
        .filter()
        .songIdEqualTo(songId)
        .sortByTimeMs()
        .watch(fireImmediately: true);
  }

  Future<List<Endpoint>> getBySong(int songId) async {
    return isar.endpoints.filter().songIdEqualTo(songId).sortByTimeMs().findAll();
  }

  Future<Endpoint> create({
    required int songId,
    required int timeMs,
    String? label,
    String? colorHex,
  }) async {
    if (timeMs < 0) {
      throw ArgumentError('timeMs deve ser >= 0');
    }

    // Pré-validação de unicidade para erro amigável
    final exists = await isar.endpoints
        .filter()
        .songIdEqualTo(songId)
        .timeMsEqualTo(timeMs)
        .isNotEmpty();
    if (exists) {
      throw StateError('Já existe um endpoint nesse tempo para esta música');
    }

    // Geração de nome padrão sequencial se não vier label
    final currentCount = await isar.endpoints.filter().songIdEqualTo(songId).count();
    final resolvedLabel = label?.trim().isNotEmpty == true
        ? label!.trim()
        : 'Endpoint ${currentCount + 1}';

    final normalizedColor = _normalizeColorHex(colorHex ?? '#FF3B30');

    final e = Endpoint()
      ..songId = songId
      ..timeMs = timeMs
      ..label = resolvedLabel
      ..colorHex = normalizedColor
      ..createdAt = DateTime.now();

    await isar.writeTxn(() async {
      await isar.endpoints.put(e);
    });
    return e;
  }

  Future<void> updateLabel(int endpointId, String newLabel) async {
    final trimmed = newLabel.trim();
    if (trimmed.isEmpty) return;
    await isar.writeTxn(() async {
      final e = await isar.endpoints.get(endpointId);
      if (e == null) return;
      e.label = trimmed;
      await isar.endpoints.put(e);
    });
  }

  Future<void> updateColor(int endpointId, String colorHex) async {
    final normalized = _normalizeColorHex(colorHex);
    await isar.writeTxn(() async {
      final e = await isar.endpoints.get(endpointId);
      if (e == null) return;
      e.colorHex = normalized;
      await isar.endpoints.put(e);
    });
  }

  Future<void> updateTimeMs(int endpointId, int newTimeMs) async {
    if (newTimeMs < 0) {
      throw ArgumentError('timeMs deve ser >= 0');
    }
    await isar.writeTxn(() async {
      final e = await isar.endpoints.get(endpointId);
      if (e == null) return;
      if (e.timeMs == newTimeMs) return;
      final conflict = await isar.endpoints
          .filter()
          .songIdEqualTo(e.songId)
          .timeMsEqualTo(newTimeMs)
          .isNotEmpty();
      if (conflict) {
        throw StateError('Já existe um endpoint nesse tempo para esta música');
      }
      e.timeMs = newTimeMs;
      await isar.endpoints.put(e);
    });
  }

  // Retorna o objeto deletado para suportar undo pela UI
  Future<Endpoint?> delete(int endpointId) async {
    Endpoint? deleted;
    await isar.writeTxn(() async {
      deleted = await isar.endpoints.get(endpointId);
      if (deleted != null) {
        await isar.endpoints.delete(endpointId);
      }
    });
    return deleted;
  }

  Future<void> restore(Endpoint endpoint) async {
    // Caso exista um conflito de unicidade (songId/timeMs), a transação falhará
    await isar.writeTxn(() async {
      await isar.endpoints.put(endpoint);
    });
  }

  String _normalizeColorHex(String input) {
    var v = input.trim();
    if (!v.startsWith('#')) v = '#$v';
    if (v.length == 4) {
      // Forma curta #RGB -> #RRGGBB
      final r = v[1];
      final g = v[2];
      final b = v[3];
      v = '#$r$r$g$g$b$b';
    }
    if (v.length != 7) {
      // Fallback para vermelho se formato inválido
      v = '#FF3B30';
    }
    return v.toUpperCase();
  }
}