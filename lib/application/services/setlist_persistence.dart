import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SetlistInfo {
  final String name;
  final List<int> songIds;
  final DateTime createdAt;
  final String path;

  SetlistInfo({
    required this.name,
    required this.songIds,
    required this.createdAt,
    required this.path,
  });
}

class SetlistPersistence {
  /// Salva um setlist como JSON em `setlists/<nome>.json` no diretório de documentos do app.
  /// Retorna o arquivo salvo.
  static Future<File> saveSetlist({
    required String name,
    required List<int> songIds,
  }) async {
    if (name.trim().isEmpty) {
      name = 'Setlist_${DateTime.now().millisecondsSinceEpoch}';
    }
    final dir = await getApplicationDocumentsDirectory();
    final setlistsDir = Directory(p.join(dir.path, 'setlists'));
    if (!await setlistsDir.exists()) {
      await setlistsDir.create(recursive: true);
    }
    final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    final filePath = p.join(setlistsDir.path, '$safeName.json');
    final payload = {
      'name': name,
      'createdAt': DateTime.now().toIso8601String(),
      'songIds': songIds,
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);
    final file = File(filePath);
    await file.writeAsString(jsonStr, flush: true);
    return file;
  }

  /// Lista todos os setlists salvos em `setlists/`.
  static Future<List<SetlistInfo>> listSetlists() async {
    final dir = await getApplicationDocumentsDirectory();
    final setlistsDir = Directory(p.join(dir.path, 'setlists'));
    if (!await setlistsDir.exists()) {
      return [];
    }
    final files = setlistsDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.json')
        .toList();
    final out = <SetlistInfo>[];
    for (final f in files) {
      try {
        final str = await f.readAsString();
        final obj = json.decode(str);
        final name = (obj['name'] as String?) ?? p.basenameWithoutExtension(f.path);
        final idsRaw = (obj['songIds'] as List?) ?? const [];
        final songIds = idsRaw.map((e) => int.tryParse('$e') ?? 0).where((e) => e != 0).toList();
        DateTime createdAt;
        final createdStr = obj['createdAt'] as String?;
        if (createdStr != null) {
          createdAt = DateTime.tryParse(createdStr) ?? await f.lastModified();
        } else {
          createdAt = await f.lastModified();
        }
        out.add(SetlistInfo(
          name: name,
          songIds: songIds,
          createdAt: createdAt,
          path: f.path,
        ));
      } catch (_) {
        // Ignora arquivos inválidos
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }
}