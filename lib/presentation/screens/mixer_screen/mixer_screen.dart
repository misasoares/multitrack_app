import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/song_providers.dart';
import '../../../application/providers/audio_providers.dart';
import '../../../application/providers/device_provider.dart';
import '../../widgets/track_control_tile.dart';
import '../../widgets/waveform_timeline.dart';
import '../../../domain/models/track_model.dart';

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
                          // Configura qualidade com sample rate da primeira track e buffer recomendado
                          try {
                            final sr = firstPath != null
                                ? await audioService.getFileSampleRateHz(firstPath)
                                : null;
                            final recommended = await audioService.getRecommendedBufferSizeFrames();
                            await audioService.setOutputQuality(
                              sampleRateHz: sr ?? 44100,
                              bitDepth: 16,
                              bufferSizeFrames: recommended ?? 2048,
                              lowLatency: false,
                            );
                          } catch (_) {}
                          await audioService.playAllTracks(tracks);
                          // Solicita início na posição atual da agulha
                          try {
                            await audioService.seekPlayAll(_playheadSec);
                          } catch (_) {}
                          // Não há um único previewId; mantemos como null para indicar mix global
                          ref.read(previewingTrackIdProvider.notifier).state =
                              null;
                          setState(() {
                            _isPlaying = true;
                            // Ajusta cronômetro para refletir o ponto atual
                            _startEpochMs =
                                DateTime.now().millisecondsSinceEpoch -
                                    (_playheadSec * 1000).round();
                          });
                          // passa playhead ao provider e inicia timer de atualização
                          ref.read(playheadSecProvider.notifier).state =
                              _playheadSec;
                          _startPlayheadTimer();
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Erro ao tocar todas: $e')),
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
                              final now = DateTime.now().millisecondsSinceEpoch;
                              _playheadSec = ((now - _startEpochMs!) / 1000.0)
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
                          ref.read(playheadSecProvider.notifier).state =
                              _playheadSec;
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
                // Aviso de divergência de sample rate entre tracks
                FutureBuilder<bool>(
                  future: _hasSampleRateMismatch(tracks),
                  builder: (context, snap) {
                    final warn = snap.data == true;
                    if (!warn) return const SizedBox.shrink();
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                      color: const Color(0xFFFFF176), // amber 300
                      child: const Text(
                        'Aviso: tracks com taxas de amostragem diferentes',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
                      ),
                    );
                  },
                ),
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

  Future<bool> _hasSampleRateMismatch(List<Track> tracks) async {
    if (tracks.isEmpty) return false;
    final audioService = ref.read(audioDeviceServiceProvider);
    final rates = <int>{};
    for (final t in tracks) {
      final path = t.localFilePath;
      if (path.isEmpty) continue;
      final sr = await audioService.getFileSampleRateHz(path);
      if (sr != null && sr > 0) {
        rates.add(sr);
      }
    }
    return rates.length > 1;
  }

  void _startPlayheadTimer() {
    _playheadTimer?.cancel();
    if (_isPlaying && _startEpochMs != null) {
      _playheadTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final sec =
            ((now - _startEpochMs!) / 1000.0).clamp(0.0, double.infinity);
        setState(() {
          _playheadSec = sec;
        });
        ref.read(playheadSecProvider.notifier).state = _playheadSec;
      });
    }
  }

  @override
  void dispose() {
    _playheadTimer?.cancel();
    super.dispose();
  }
}
