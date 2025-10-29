import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/songs_provider.dart';
import '../add_song_screen.dart';
import 'edit_song_screen.dart';
import '../mixer_screen/mixer_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSongs = ref.watch(songsListProvider);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Biblioteca de Músicas'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: asyncSongs.when(
        data: (songs) {
          if (songs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.library_music_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Nenhuma música encontrada',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Toque no botão + para adicionar uma música',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }
          
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Icon(Icons.music_note, color: Colors.white),
                  ),
                  title: Text(
                    song.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: FutureBuilder<int>(
                    future: _getTrackCount(ref, song.id),
                    builder: (context, snapshot) {
                      final trackCount = snapshot.data ?? 0;
                      return Text('$trackCount faixas');
                    },
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => EditSongScreen(songId: song.id),
                              ),
                            );
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _showDeleteDialog(context, ref, song.id, song.name),
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MixerScreen(songId: song.id),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('Erro ao carregar músicas: $error'),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AddSongScreen()),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<int> _getTrackCount(WidgetRef ref, int songId) async {
    final song = await ref.read(songWithTracksProvider(songId).future);
    return song?.tracks.length ?? 0;
  }

  void _showDeleteDialog(BuildContext context, WidgetRef ref, int songId, String songName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir Música'),
        content: Text('Tem certeza que deseja excluir "$songName"?\nEsta ação não pode ser desfeita.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(songServiceProvider).deleteSong(songId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Música "$songName" excluída')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }
}