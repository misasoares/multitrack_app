import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/song_providers.dart';
import '../../../application/providers/audio_providers.dart';
import '../../../application/providers/device_provider.dart';
import '../../widgets/track_control_tile.dart';
import '../../widgets/waveform_timeline.dart';

class MixerScreen extends ConsumerStatefulWidget {
  final int songId;
  const MixerScreen({super.key, required this.songId});
  @override
  ConsumerState<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends ConsumerState<MixerScreen> {
  bool _isPlaying = false;
  int? _startEpochMs;
  double _playheadSec = 0.0; // posição atual da agulha em segundos
  double _lastPublishedSec = 0.0; // último valor enviado ao provider
  Timer? _playheadTimer;

  @override
  Widget build(BuildContext context) {
    final songAsync = ref.watch(currentSongProvider(widget.songId));

    return songAsync.when(
      data: (song) {
        if (song == null) {
          return const Scaffold(
            body: Center(child: Text('Música não encontrada')),
          );
        }
        final tracks = song.tracks.toList();
        final firstPath = tracks.isNotEmpty ? tracks.first.localFilePath : null;
        return Scaffold(
          appBar: AppBar(
            title: Text(song.name),
            centerTitle: true,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(72),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Play a partir da agulha atual',
                      icon: const Icon(Icons.play_circle_fill),
                      iconSize: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      constraints:
                          const BoxConstraints(minWidth: 60, minHeight: 48),
                      onPressed: () async {
                        final audioService =
                            ref.read(audioDeviceServiceProvider);
                        if (tracks.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Nenhuma track para tocar')),
                          );
                          return;
                        }
                        try {
                          await audioService.stopPreview();
                          await audioService.playAllTracks(tracks);
                          // Solicita início na posição atual da agulha
                          try {
                            await audioService.seekPlayAll(_playheadSec);
                          } catch (_) {}
                          // Não há um único previewId; mantemos como null para indicar mix global
                          ref
                              .read(previewingTrackIdProvider.notifier)
                              .state = null;
                          setState(() {
                            _isPlaying = true;
                            // Ajusta cronômetro para refletir o ponto atual
                            _startEpochMs =
                                DateTime.now().millisecondsSinceEpoch -
                                    (_playheadSec * 1000).round();
                          });
                          // passa playhead ao provider e inicia timer de atualização
                          ref.read(playheadSecProvider.notifier).state = _playheadSec;
                          _lastPublishedSec = _playheadSec;
                          _startPlayheadTimer();
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content:
                                    Text('Erro ao tocar todas: $e')),
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      tooltip: 'Pausar preview',
                      icon: const Icon(Icons.pause_circle_filled),
                      iconSize: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      constraints:
                          const BoxConstraints(minWidth: 60, minHeight: 48),
                      onPressed: () async {
                        try {
                          final audioService =
                              ref.read(audioDeviceServiceProvider);
                          await audioService.stopPreview();
                          setState(() {
                            // Captura a posição atual antes de pausar
                            if (_isPlaying && _startEpochMs != null) {
                              final now =
                                  DateTime.now().millisecondsSinceEpoch;
                              _playheadSec =
                                  ((now - _startEpochMs!) / 1000.0)
                                      .clamp(0.0, double.infinity);
                              // Reancora o cronômetro no ponto atual
                              _startEpochMs =
                                  now - (_playheadSec * 1000).round();
                            }
                            _isPlaying = false;
                            // Mantém _startEpochMs; a UI de tempo congela no ponto atual
                          });
                          // para timer e publica playhead atual
                          _playheadTimer?.cancel();
                          ref.read(playheadSecProvider.notifier).state = _playheadSec;
                          _lastPublishedSec = _playheadSec;
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Falha ao pausar: $e')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timeline fixa acima dos faders
                WaveformTimeline(
                  filePath: firstPath,
                  isPlaying: _isPlaying,
                  startEpochMs: _startEpochMs,
                  height: 120,
                  onSeek: (sec) async {
                    // Ajusta playhead local para refletir o seek
                    setState(() {
                      _playheadSec = sec;
                      // Faz o cronômetro refletir o novo ponto
                      _startEpochMs = DateTime.now().millisecondsSinceEpoch -
                          (sec * 1000).round();
                    });
                    // atualiza provider imediatamente
                    ref.read(playheadSecProvider.notifier).state = _playheadSec;
                    _lastPublishedSec = _playheadSec;
                    // Solicita seek no mixer nativo, se suportado
                    try {
                      final audioService = ref.read(audioDeviceServiceProvider);
                      await audioService.seekPlayAll(sec);
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Falha ao buscar posição: $e')),
                      );
                    }
                  },
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final h = constraints.maxHeight;
                      return SizedBox(
                        height: h,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 16, horizontal: 8),
                            child: SizedBox(
                              height: h - 32,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  for (int i = 0; i < tracks.length; i++)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                      child: SizedBox(
                                        height: h - 32,
                                        child: TrackControlTile(
                                            track: tracks[i], trackIndex: i),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Scaffold(
        body: Center(child: Text('Erro ao carregar música: $e')),
      ),
    );
  }

  void _startPlayheadTimer() {
    _playheadTimer?.cancel();
    if (_isPlaying && _startEpochMs != null) {
      _playheadTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final sec = ((now - _startEpochMs!) / 1000.0).clamp(0.0, double.infinity);
        // Atualiza somente provider; evita rebuild do Mixer inteiro a cada tick
        _playheadSec = sec;
        if ((sec - _lastPublishedSec).abs() >= 0.02) {
          ref.read(playheadSecProvider.notifier).state = sec;
          _lastPublishedSec = sec;
        }
      });
    }
  }

  @override
  void dispose() {
    _playheadTimer?.cancel();
    super.dispose();
  }
}
