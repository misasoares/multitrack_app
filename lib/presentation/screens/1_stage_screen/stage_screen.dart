import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'setlist_editor_screen.dart';
import '../../../application/providers/setlists_provider.dart';
import '../../../application/services/setlist_persistence.dart';

class StageScreen extends ConsumerStatefulWidget {
  const StageScreen({super.key});

  @override
  ConsumerState<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends ConsumerState<StageScreen> {
  String _formatDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final setlistsAsync = ref.watch(setlistsListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Palco'),
        actions: [
          IconButton(
            tooltip: 'Atualizar lista',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.refresh(setlistsListProvider),
          ),
          IconButton(
            tooltip: 'Criar setlist',
            icon: const Icon(Icons.playlist_add),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SetlistEditorScreen()),
              );
            },
          ),
        ],
      ),
      body: setlistsAsync.when(
        data: (list) {
          final setlists = list as List<SetlistInfo>;
          if (setlists.isEmpty) {
            return const Center(
              child: Text('Nenhum setlist salvo. Crie um novo para começar.'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: setlists.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, idx) {
              final s = setlists[idx];
              return Card(
                elevation: 1,
                child: ListTile(
                  title: Text(s.name),
                  subtitle: Text(
                    'Músicas: ${s.songIds.length} • ${_formatDate(s.createdAt)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    // Futuro: abrir setlist para execução/edição
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Setlist: ${s.name}')),
                    );
                  },
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Erro ao listar setlists: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Novo setlist',
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SetlistEditorScreen()),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}