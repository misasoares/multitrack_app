import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models/staged_track_model.dart';
import '../../domain/models/track_model.dart';
import '../../domain/models/song_model.dart';
import '../providers/database_provider.dart';
import '../providers/songs_provider.dart';

class AddSongState {
  final String songName;
  final List<StagedTrack> stagedTracks;
  final bool isLoadingFiles;
  final bool isSaving;
  final String? errorMessage;

  AddSongState({
    this.songName = '', 
    List<StagedTrack>? stagedTracks,
    this.isLoadingFiles = false,
    this.isSaving = false,
    this.errorMessage,
  }) : stagedTracks = stagedTracks ?? [];

  AddSongState copyWith({
    String? songName, 
    List<StagedTrack>? stagedTracks,
    bool? isLoadingFiles,
    bool? isSaving,
    String? errorMessage,
  }) {
    return AddSongState(
      songName: songName ?? this.songName,
      stagedTracks: stagedTracks ?? this.stagedTracks,
      isLoadingFiles: isLoadingFiles ?? this.isLoadingFiles,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: errorMessage,
    );
  }

  // Usa checagem defensiva para evitar crashes após hot reload
  bool get isLoading {
    try {
      return (isLoadingFiles == true) || (isSaving == true);
    } catch (_) {
      // Em cenários raros de hot reload, campos podem estar nulos em instâncias antigas
      return false;
    }
  }
}

class AddSongNotifier extends StateNotifier<AddSongState> {
  AddSongNotifier() : super(AddSongState());

  void setSongName(String name) {
    state = state.copyWith(songName: name);
  }

  void renameTrack(int index, String newName) {
    final list = [...state.stagedTracks];
    if (index >= 0 && index < list.length) {
      list[index].displayName = newName;
      state = state.copyWith(stagedTracks: list);
    }
  }

  void removeTrack(int index) {
    final list = [...state.stagedTracks];
    if (index >= 0 && index < list.length) {
      list.removeAt(index);
      state = state.copyWith(stagedTracks: list);
    }
  }

  Future<void> pickAndAddTracks(bool allowMultiple, bool pickDirectory) async {
    try {
      state = state.copyWith(isLoadingFiles: true, errorMessage: null);
      
      List<String> paths = [];
      if (pickDirectory) {
        final dirPath = await FilePicker.platform.getDirectoryPath();
        if (dirPath != null) {
          final dir = Directory(dirPath);
          final files = dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) {
            final ext = p.extension(f.path).toLowerCase();
            return ext == '.wav' || ext == '.mp3';
          })
              .map((f) => f.path)
              .toList();
          paths.addAll(files);
        }
      } else {
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: allowMultiple,
          type: FileType.custom,
          allowedExtensions: ['wav', 'mp3'],
          withData: false,
        );
        if (result != null) {
          paths.addAll(result.files.map((f) => f.path).whereType<String>());
        }
      }

      if (paths.isNotEmpty) {
        final staged = [...state.stagedTracks];
        for (final path in paths) {
          final name = p.basenameWithoutExtension(path);
          staged.add(StagedTrack(originalFilePath: path, displayName: name));
        }
        state = state.copyWith(stagedTracks: staged, isLoadingFiles: false);
      } else {
        state = state.copyWith(isLoadingFiles: false);
      }
    } catch (e) {
      state = state.copyWith(
        isLoadingFiles: false, 
        errorMessage: 'Erro ao importar arquivos: $e'
      );
    }
  }

  Future<void> saveSong(WidgetRef ref) async {
    if (state.songName.isEmpty || state.stagedTracks.isEmpty) {
      final message = state.songName.isEmpty
          ? 'O nome da música é obrigatório!'
          : 'É necessário adicionar pelo menos uma faixa!';
      state = state.copyWith(errorMessage: message);
      return;
    }

    try {
      state = state.copyWith(isSaving: true, errorMessage: null);

      final isar = await ref.read(isarProvider.future);
      final appDir = await getApplicationDocumentsDirectory();
      final tracks = <Track>[];
      final uuid = const Uuid();

      for (final staged in state.stagedTracks) {
        final ext = p.extension(staged.originalFilePath);
        final uniqueName = '${uuid.v4()}$ext';
        final newPath = p.join(appDir.path, 'audio', uniqueName);

        final destDir = Directory(p.dirname(newPath));
        if (!destDir.existsSync()) {
          destDir.createSync(recursive: true);
        }

        final srcFile = File(staged.originalFilePath);
        await srcFile.copy(newPath);

        final track = Track()
          ..name = staged.displayName
          ..localFilePath = newPath;
        tracks.add(track);
      }

      final newSong = Song()..name = state.songName;

      await isar.writeTxn(() async {
        await isar.tracks.putAll(tracks);
        await isar.songs.put(newSong);
        newSong.tracks.addAll(tracks);
        await newSong.tracks.save();
      });

      // Atualiza a lista na biblioteca ao retornar
      ref.invalidate(songsListProvider);

      // Reset state
      state = AddSongState();
    } catch (e) {
      state = state.copyWith(
        isSaving: false, 
        errorMessage: 'Erro ao salvar música: $e'
      );
    }
  }
}