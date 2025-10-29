import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/song_providers.dart';

class AddSongScreen extends ConsumerWidget {
  const AddSongScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(addSongProvider);
    final notifier = ref.read(addSongProvider.notifier);

    // Mostrar erro se houver
    if (state.errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(state.errorMessage!),
            backgroundColor: Colors.red,
          ),
        );
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Importar Nova Música')),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  enabled: !state.isLoading,
                  decoration: const InputDecoration(
                    labelText: 'Nome da Música',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: notifier.setSongName,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: state.stagedTracks.length,
                  itemBuilder: (context, index) {
                    final track = state.stagedTracks[index];
                    return ListTile(
                      title: Text(track.displayName),
                      subtitle: Text(track.originalFilePath),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: state.isLoading
                                ? null
                                : () async {
                                    final controller = TextEditingController(
                                        text: track.displayName);
                                    final newName = await showDialog<String>(
                                      context: context,
                                      builder: (ctx) {
                                        return AlertDialog(
                                          title: const Text('Renomear Faixa'),
                                          content: TextField(
                                            controller: controller,
                                            decoration: const InputDecoration(
                                              labelText: 'Novo nome',
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx),
                                              child: const Text('Cancelar'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () {
                                                final newName =
                                                    controller.text.trim();
                                                if (newName.isEmpty) {
                                                  ScaffoldMessenger.of(ctx)
                                                      .showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                          'O nome da faixa não pode estar vazio!'),
                                                      backgroundColor:
                                                          Colors.red,
                                                    ),
                                                  );
                                                  return;
                                                }
                                                Navigator.pop(ctx, newName);
                                              },
                                              child: const Text('Salvar'),
                                            ),
                                          ],
                                        );
                                      },
                                    );
                                    if (newName != null && newName.isNotEmpty) {
                                      notifier.renameTrack(index, newName);
                                    }
                                  },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: state.isLoading
                                ? null
                                : () => notifier.removeTrack(index),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: state.isLoading
                            ? null
                            : () => notifier.pickAndAddTracks(true, false),
                        child: (state.isLoadingFiles == true)
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 8),
                                  Text('Carregando...'),
                                ],
                              )
                            : const Text('Adicionar Faixas'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: state.isLoading
                            ? null
                            : () => notifier.pickAndAddTracks(false, true),
                        child: (state.isLoadingFiles == true)
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 8),
                                  Text('Carregando...'),
                                ],
                              )
                            : const Text('Adicionar Pasta'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Overlay de loading
          if (state.isLoading)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Processando...'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: (state.isSaving == true)
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                      SizedBox(width: 12),
                      Text('Salvando...'),
                    ],
                  )
                : const Text('Salvar Música'),
          ),
          onPressed: (state.isLoading || state.stagedTracks.isEmpty)
              ? null
              : () async {
                  // Validação: nome da música é obrigatório
                  final songName = state.songName.trim();
                  if (songName.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('O nome da música é obrigatório!'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  // Validação: precisa ter pelo menos uma faixa
                  if (state.stagedTracks.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Adicione pelo menos uma faixa para salvar a música!'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  // Validação: nomes das faixas são obrigatórios
                  bool hasValidTracks = state.stagedTracks
                      .any((track) => track.displayName.trim().isNotEmpty);
                  if (!hasValidTracks && state.stagedTracks.isNotEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Todas as faixas devem ter um nome!'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  await notifier.saveSong(ref);
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          ),
        ),
      ),
    );
  }
}
