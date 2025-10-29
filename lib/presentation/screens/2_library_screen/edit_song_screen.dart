import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/songs_provider.dart';
import '../../../domain/models/song_model.dart';
import '../../../domain/models/track_model.dart';

class EditSongScreen extends ConsumerStatefulWidget {
  final int songId;

  const EditSongScreen({super.key, required this.songId});

  @override
  ConsumerState<EditSongScreen> createState() => _EditSongScreenState();
}

class _EditSongScreenState extends ConsumerState<EditSongScreen> {
  late TextEditingController _songNameController;
  final Map<int, TextEditingController> _trackControllers = {};
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _songNameController = TextEditingController();
  }

  @override
  void dispose() {
    _songNameController.dispose();
    for (final controller in _trackControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncSong = ref.watch(songWithTracksProvider(widget.songId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar Música'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          _isSaving
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.save),
                onPressed: () => _saveSong(),
              ),
        ],
      ),
      body: asyncSong.when(
        data: (song) {
          if (song == null) {
            return const Center(
              child: Text('Música não encontrada'),
            );
          }

          // Inicializa os controladores se ainda não foram inicializados
          if (_songNameController.text.isEmpty) {
            _songNameController.text = song.name;
          }

          for (final track in song.tracks) {
            if (!_trackControllers.containsKey(track.id)) {
              _trackControllers[track.id] = TextEditingController(text: track.name);
            }
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Seção do nome da música
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Nome da Música',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _songNameController,
                          enabled: !_isSaving,
                          decoration: const InputDecoration(
                            labelText: 'Nome da música',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.music_note),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // Seção das faixas
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Faixas',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${song.tracks.length} faixas',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        
                        if (song.tracks.isEmpty)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Column(
                                children: [
                                  Icon(Icons.audiotrack, size: 48, color: Colors.grey),
                                  SizedBox(height: 12),
                                  Text(
                                    'Nenhuma faixa encontrada',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ...song.tracks.toList().asMap().entries.map((entry) {
                            final index = entry.key;
                            final track = entry.value;
                            final controller = _trackControllers[track.id]!;
                            
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.withOpacity(0.3)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.orange,
                                  child: Text(
                                    '${index + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                title: TextField(
                                  controller: controller,
                                  enabled: !_isSaving,
                                  decoration: const InputDecoration(
                                    labelText: 'Nome da faixa',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    children: [
                                      Icon(Icons.volume_up, size: 16, color: Colors.grey[600]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Volume: ${(track.volume * 100).toInt()}%',
                                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                                      ),
                                      const SizedBox(width: 16),
                                      Icon(Icons.settings_input_component, size: 16, color: Colors.grey[600]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Canal: ${track.outputChannel + 1}',
                                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('Erro ao carregar música: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Voltar'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveSong() async {
    if (_isSaving) return;
    
    setState(() {
      _isSaving = true;
    });

    try {
      // Validação: nome da música é obrigatório
      final songName = _songNameController.text.trim();
      if (songName.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('O nome da música é obrigatório!'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validação: nomes das faixas são obrigatórios
      for (final entry in _trackControllers.entries) {
        final trackName = entry.value.text.trim();
        if (trackName.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Todas as faixas devem ter um nome!'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
      }
      
      final songService = ref.read(songServiceProvider);
      
      // Salva o nome da música
      await songService.updateSongName(widget.songId, songName);
      
      // Salva os nomes das faixas
      for (final entry in _trackControllers.entries) {
        final trackId = entry.key;
        final controller = entry.value;
        await songService.updateTrackName(trackId, controller.text.trim());
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Alterações salvas com sucesso!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao salvar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}