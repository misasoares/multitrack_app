import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/song_providers.dart';
import '../../../application/providers/audio_providers.dart';
import '../../../application/providers/device_provider.dart';
import '../../widgets/track_control_tile.dart';
import '../../widgets/waveform_timeline.dart';
import '../../widgets/waveform_loader_io.dart'
    if (dart.library.html) '../../widgets/waveform_loader_web.dart' as wf;
import '../../../domain/models/track_model.dart';
import '../../../application/providers/endpoint_providers.dart';
import '../../../domain/models/endpoint_model.dart';

class MixerScreen extends ConsumerStatefulWidget {
  final int songId;
  const MixerScreen({super.key, required this.songId});
  @override
  ConsumerState<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends ConsumerState<MixerScreen> {
  // Cache leve em memória por música para grade de batidas e período
  final Map<int, List<int>> _beatGridCacheMs = {};
  final Map<int, int> _beatPeriodMsCache = {};
  final Set<int> _beatGridComputing = {};

  List<int>? _getCachedBeatGridMs(int songId) => _beatGridCacheMs[songId];
  int? _getCachedBeatPeriodMs(int songId) => _beatPeriodMsCache[songId];

  int _computeSnapToleranceMs(int periodMs) {
    final tol = (periodMs * 0.10).round();
    if (tol < 25) return 25;
    if (tol > 60) return 60;
    return tol;
  }

  int _nearestBeatTimeMs(int rawMs, List<int> beats) {
    if (beats.isEmpty) return rawMs;
    // Busca binária para o mais próximo
    int lo = 0, hi = beats.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = beats[mid];
      if (v == rawMs) return v;
      if (v < rawMs) lo = mid + 1; else hi = mid - 1;
    }
    final candidates = <int>[];
    if (lo < beats.length) candidates.add(beats[lo]);
    if (hi >= 0) candidates.add(beats[hi]);
    if (candidates.isEmpty) return rawMs;
    candidates.sort((a, b) => (a - rawMs).abs().compareTo((b - rawMs).abs()));
    return candidates.first;
  }

  Future<bool> _ensureBeatGridComputed(int songId) async {
    if (_beatGridCacheMs.containsKey(songId) &&
        (_beatGridCacheMs[songId]?.isNotEmpty == true) &&
        _beatPeriodMsCache.containsKey(songId)) {
      return true;
    }
    if (_beatGridComputing.contains(songId)) return false;
    _beatGridComputing.add(songId);
    try {
      final metroTrackId = ref.read(metronomeTrackIdProvider);
      if (metroTrackId == null) return false;
      final asyncSong = ref.read(currentSongProvider(songId));
      final song = asyncSong.value;
      if (song == null) return false;
      final track = song.tracks.firstWhere(
        (t) => t.id == metroTrackId,
        orElse: () => song.tracks.firstWhere((t) => t.isMetronome,
            orElse: () => song.tracks.first),
      );
      final path = track.localFilePath;
      if (path.isEmpty) return false;
      final data = await wf.loadWaveform(path, targetPoints: 4000);
      final peaks = data.peaks;
      final durationSec = data.durationSec;
      final beatsMs = _detectBeatTimesMs(peaks, durationSec);
      if (beatsMs.length < 2) return false;
      // Estima período pelo mediano dos intervalos
      final intervals = <int>[];
      for (int i = 1; i < beatsMs.length; i++) {
        intervals.add(beatsMs[i] - beatsMs[i - 1]);
      }
      intervals.sort();
      final median = intervals[intervals.length ~/ 2];
      _beatGridCacheMs[songId] = beatsMs;
      _beatPeriodMsCache[songId] = median;
      return true;
    } catch (_) {
      return false;
    } finally {
      _beatGridComputing.remove(songId);
    }
  }

  List<int> _detectBeatTimesMs(List<double> peaks, double durationSec) {
    if (peaks.isEmpty || durationSec <= 0) return const [];
    final n = peaks.length;
    final dtSec = durationSec / n;
    // Estatísticas globais simples
    double sum = 0.0;
    for (final v in peaks) sum += v;
    final mean = sum / n;
    final sorted = [...peaks]..sort();
    final p80 = sorted[(0.8 * (n - 1)).round()];
    final baseThresh = (mean * 0.4 + p80 * 0.6).clamp(0.05, 0.9);
    // Janela local para máximo (para evitar falsas detecções)
    final minSepSec = 0.25; // 250ms mínimo entre picos
    final int minSepSamples = math.max(1, math.min(n, (minSepSec / dtSec).round()));
    final int halfWin = math.max(1, math.min(n, (minSepSamples / 2).floor()));
    final beatIdx = <int>[];
    int lastIdx = -minSepSamples;
    for (int i = 0; i < n; i++) {
      final amp = peaks[i];
      if (amp < baseThresh) continue;
      // Confirma se é máximo local na janela
      final int start = math.max(0, math.min(n - 1, i - halfWin));
      final int end = math.max(0, math.min(n - 1, i + halfWin));
      bool isMax = true;
      for (int j = start; j <= end; j++) {
        if (peaks[j] > amp) {
          isMax = false;
          break;
        }
      }
      if (!isMax) continue;
      if (i - lastIdx < minSepSamples) continue;
      beatIdx.add(i);
      lastIdx = i;
    }
    if (beatIdx.length < 2) return const [];
    // Refino: remove outliers de intervalos (>20% do mediano)
    final timesMs = beatIdx
        .map((i) => ((i * dtSec) * 1000).round())
        .toList(growable: true);
    final intervals = <int>[];
    for (int i = 1; i < timesMs.length; i++) {
      intervals.add(timesMs[i] - timesMs[i - 1]);
    }
    intervals.sort();
    final median = intervals[intervals.length ~/ 2];
    final maxDev = (median * 0.20).round();
    final refined = <int>[];
    refined.add(timesMs.first);
    for (int i = 1; i < timesMs.length; i++) {
      final diff = timesMs[i] - timesMs[i - 1];
      if ((diff - median).abs() <= maxDev) refined.add(timesMs[i]);
    }
    return refined.length >= 2 ? refined : timesMs;
  }
  bool _isPlaying = false;
  int? _startEpochMs;
  double _playheadSec = 0.0; // posição atual da agulha em segundos
  Timer? _playheadTimer;

  @override
  Widget build(BuildContext context) {
    final isBusy = ref.watch(mixerBusyProvider);
    final songAsync = ref.watch(currentSongProvider(widget.songId));
    final endpointsAsync = ref.watch(endpointsBySongProvider(widget.songId));

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
                      tooltip: _isPlaying
                          ? 'Pausar reprodução'
                          : 'Tocar a partir da agulha atual',
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                      ),
                      iconSize: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      constraints:
                          const BoxConstraints(minWidth: 60, minHeight: 48),
                      onPressed: () async {
                        final audioService =
                            ref.read(audioDeviceServiceProvider);
                        if (_isPlaying) {
                          // Toggle para pausar
                          try {
                            await audioService.stopPreview();
                            setState(() {
                              if (_startEpochMs != null) {
                                final now =
                                    DateTime.now().millisecondsSinceEpoch;
                                _playheadSec = ((now - _startEpochMs!) /
                                        1000.0)
                                    .clamp(0.0, double.infinity);
                                _startEpochMs =
                                    now - (_playheadSec * 1000).round();
                              }
                              _isPlaying = false;
                            });
                            _playheadTimer?.cancel();
                            ref
                                .read(playheadSecProvider.notifier)
                                .state = _playheadSec;
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Falha ao pausar: $e')),
                            );
                          }
                          return;
                        }

                        // Toggle para tocar
                        if (tracks.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Nenhuma track para tocar')),
                          );
                          return;
                        }
                        try {
                          await audioService.stopPreview();
                          try {
                            final sr = firstPath != null
                                ? await audioService
                                    .getFileSampleRateHz(firstPath)
                                : null;
                            final recommended = await audioService
                                .getRecommendedBufferSizeFrames();
                            await audioService.setOutputQuality(
                              sampleRateHz: sr ?? 44100,
                              bitDepth: 16,
                              bufferSizeFrames: recommended ?? 2048,
                              lowLatency: false,
                            );
                          } catch (_) {}
                          await audioService.playAllTracks(tracks);
                          try {
                            await audioService.seekPlayAll(_playheadSec);
                          } catch (_) {}
                          ref.read(previewingTrackIdProvider.notifier).state =
                              null;
                          setState(() {
                            _isPlaying = true;
                            _startEpochMs =
                                DateTime.now().millisecondsSinceEpoch -
                                    (_playheadSec * 1000).round();
                          });
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
                      tooltip: 'Adicionar endpoint na posição atual',
                      icon: const Icon(Icons.add_location),
                      iconSize: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      constraints:
                          const BoxConstraints(minWidth: 60, minHeight: 48),
                      onPressed: () async {
                        try {
                          final svc = ref.read(endpointServiceProvider);
                          // Tempo bruto na agulha atual
                          final rawMs = (_playheadSec * 1000).round();
                          // Liga snap automaticamente se grade pronta
                          final metroId = ref.read(metronomeTrackIdProvider);
                          if (ref.read(snapToBeatsProvider) == false &&
                              metroId != null) {
                            final ok = await _ensureBeatGridComputed(widget.songId);
                            if (ok) {
                              ref.read(snapToBeatsProvider.notifier).state = true;
                            }
                          }
                          // Aplica snap caso habilitado e haja faixa metrônomo
                          final timeMs = _maybeSnapTimeMs(rawMs);
                          // Evita duplicata amigavelmente
                          final eps = ref.read(endpointsBySongProvider(widget.songId)).value;
                          if (eps != null && eps.any((e) => e.timeMs == timeMs)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Já existe um endpoint nesse tempo (após snap)'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                            return;
                          }
                          await svc.create(
                            songId: widget.songId,
                            timeMs: timeMs,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Endpoint adicionado'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content:
                                    Text('Falha ao adicionar endpoint: $e')),
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    Builder(builder: (context) {
                      final snap = ref.watch(snapToBeatsProvider);
                      final metronomeId = ref.watch(metronomeTrackIdProvider);
                      final hasMetro = metronomeId != null;
                      final canToggle = hasMetro;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: snap,
                            onChanged: canToggle
                                ? (v) async {
                                    if (v) {
                                      // ao ligar, busca/gera grade
                                      final ok = await _ensureBeatGridComputed(widget.songId);
                                      if (!ok) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Grade do metrônomo indisponível'),
                                          ),
                                        );
                                        return;
                                      }
                                    }
                                    ref.read(snapToBeatsProvider.notifier).state = v;
                                  }
                                : null,
                          ),
                          const SizedBox(width: 4),
                          Text('Snap ao metrônomo',
                              style: TextStyle(
                                  color: canToggle ? null : Colors.grey)),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('Detectar BPM'),
                            onPressed: hasMetro && snap
                                ? () async {
                                    try {
                                      final asyncSong = ref.read(currentSongProvider(widget.songId));
                                      final song = asyncSong.value;
                                      if (song == null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Música ainda não carregada')),
                                        );
                                        return;
                                      }
                                      final track = song.tracks.firstWhere(
                                        (t) => t.id == metronomeId,
                                        orElse: () => song.tracks.firstWhere(
                                          (t) => t.isMetronome,
                                          orElse: () => song.tracks.first,
                                        ),
                                      );
                                      ref.read(mixerBusyProvider.notifier).state = true;
                                      final analyzer = ref.read(bpmAnalyzerServiceProvider);
                                      final result = await analyzer.detectFromFile(track.localFilePath);
                                      ref.read(songBpmProvider(widget.songId).notifier).state = result.bpm;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('BPM detectado: ${result.bpm} (confiança ${(result.confidence * 100).round()}%)'),
                                        ),
                                      );
                                    } catch (e) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Falha na detecção de BPM: $e')),
                                      );
                                    } finally {
                                      ref.read(mixerBusyProvider.notifier).state = false;
                                    }
                                  }
                                : null,
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          body: SafeArea(
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Container(
                        color: const Color(0xFF121212),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                              child: Text(
                                'Endpoints',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            // Snap agora é controlado apenas pela AppBar; seção removida
                            const Divider(height: 1),
                            Expanded(
                              child: endpointsAsync.when(
                                data: (list) {
                                  if (list.isEmpty) {
                                    return const Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Text(
                                          'Nenhum endpoint. Use + para criar.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ),
                                    );
                                  }
                                  return ListView.separated(
                                    itemCount: list.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, index) {
                                      final ep = list[index];
                                      return _EndpointTile(
                                        endpoint: ep,
                                        onGo: () async {
                                          await _goToEndpoint(ep);
                                        },
                                        onRename: () async {
                                          await _renameEndpoint(context, ep);
                                        },
                                        onPickColor: () async {
                                          await _pickColor(context, ep);
                                        },
                                        onDelete: () async {
                                          await _deleteEndpoint(context, ep);
                                        },
                                      );
                                    },
                                  );
                                },
                                loading: () => const Center(
                                    child: CircularProgressIndicator()),
                                error: (e, _) => Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text('Erro: $e'),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FutureBuilder<bool>(
                            future: _hasSampleRateMismatch(tracks),
                            builder: (context, snap) {
                              final warn = snap.data == true;
                              if (!warn) return const SizedBox.shrink();
                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 6, horizontal: 12),
                                color: const Color(0xFFFFF176),
                                child: const Text(
                                  'Aviso: tracks com taxas de amostragem diferentes',
                                  style: TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.w600),
                                ),
                              );
                            },
                          ),
                          WaveformTimeline(
                            filePath: firstPath,
                            isPlaying: _isPlaying,
                            startEpochMs: _startEpochMs,
                            height: 120,
                            endpoints: endpointsAsync.value ?? const [],
                            onTapEndpoint: (ep) {
                              _goToEndpoint(ep);
                            },
                            onSeek: (sec) async {
                              setState(() {
                                _playheadSec = sec;
                                _startEpochMs =
                                    DateTime.now().millisecondsSinceEpoch -
                                        (sec * 1000).round();
                              });
                              ref.read(playheadSecProvider.notifier).state =
                                  _playheadSec;
                              try {
                                final audioService =
                                    ref.read(audioDeviceServiceProvider);
                                await audioService.seekPlayAll(sec);
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content:
                                          Text('Falha ao buscar posição: $e')),
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            for (int i = 0;
                                                i < tracks.length;
                                                i++)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 8),
                                                child: SizedBox(
                                                  height: h - 32,
                                                  child: TrackControlTile(
                                                      track: tracks[i],
                                                      trackIndex: i,
                                                      songId: widget.songId),
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
                  ],
                ),
                if (isBusy)
                  Positioned.fill(
                    child: AbsorbPointer(
                      absorbing: true,
                      child: Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text('Analisando BPM... Aguarde',
                                  style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
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

  // Quantiza o tempo em ms se Snap estiver ativo e houver faixa marcada como metrônomo
  int _maybeSnapTimeMs(int rawMs) {
    final snapOn = ref.read(snapToBeatsProvider);
    final metroTrackId = ref.read(metronomeTrackIdProvider);
    if (!snapOn || metroTrackId == null) return rawMs;
    final grid = _getCachedBeatGridMs(widget.songId);
    final period = _getCachedBeatPeriodMs(widget.songId);
    if (grid == null || grid.isEmpty || period == null || period <= 0) {
      return rawMs;
    }
    final tol = _computeSnapToleranceMs(period);
    final snapped = _nearestBeatTimeMs(rawMs, grid);
    if ((snapped - rawMs).abs() <= tol) return snapped;
    return rawMs;
  }

  int _nearestGridMs(int value, int gridMs) {
    if (gridMs <= 0) return value;
    final lower = (value / gridMs).floor() * gridMs;
    final upper = lower + gridMs;
    return (value - lower) < (upper - value) ? lower : upper;
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

  int _xfadeToken = 0;
  Future<void> _seekWithCrossfade({
    required double positionSec,
    required List<Track> tracks,
    int durationMs = 80,
    int steps = 6,
    double minGain = 0.35,
  }) async {
    if (tracks.isEmpty || durationMs <= 0 || steps <= 0) {
      final audioService = ref.read(audioDeviceServiceProvider);
      await audioService.seekPlayAll(positionSec);
      return;
    }
    final audioService = ref.read(audioDeviceServiceProvider);
    final original = tracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
    final localToken = ++_xfadeToken;
    final stepDelay =
        Duration(milliseconds: (durationMs / steps).round());

    bool cancelled() => localToken != _xfadeToken;
    // Equal-power micro crossfade estilo "X"
    final half = math.max(1, math.min(steps - 1, steps ~/ 2));
    for (int i = 0; i <= steps; i++) {
      double factor;
      if (i < half) {
        final t = i / half; // 0..1
        final cosv = math.cos((math.pi / 2) * t); // 1..0
        factor = (minGain + (1 - minGain) * cosv).clamp(minGain, 1.0);
      } else if (i == half) {
        try {
          await audioService.seekPlayAll(positionSec);
        } catch (_) {}
        if (cancelled()) return;
        factor = minGain;
      } else {
        final t = (i - half) / (steps - half); // 0..1
        final sinv = math.sin((math.pi / 2) * t); // 0..1
        factor = (minGain + (1 - minGain) * sinv).clamp(minGain, 1.0);
      }

      final futures = <Future>[];
      for (int ti = 0; ti < original.length; ti++) {
        futures.add(audioService.setTrackVolume(ti, original[ti] * factor));
      }
      await Future.wait(futures);
      if (i < steps) {
        await Future.delayed(stepDelay);
        if (cancelled()) return;
      }
    }
  }

  Future<void> _goToEndpoint(Endpoint ep) async {
    final sec = ep.timeMs / 1000.0;
    setState(() {
      _playheadSec = sec;
      _startEpochMs =
          DateTime.now().millisecondsSinceEpoch - (sec * 1000).round();
    });
    ref.read(playheadSecProvider.notifier).state = _playheadSec;
    try {
      final audioService = ref.read(audioDeviceServiceProvider);
      if (_isPlaying) {
        final song = await ref.read(currentSongProvider(widget.songId).future);
        final tracks = song?.tracks.toList() ?? const [];
        await _seekWithCrossfade(positionSec: sec, tracks: tracks);
      } else {
        // Inicia reprodução automaticamente se estiver pausado
        final song = await ref.read(currentSongProvider(widget.songId).future);
        if (song == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Música ainda não carregada')),
            );
          }
          return;
        }
        final tracks = song.tracks.toList();
        if (tracks.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nenhuma track para tocar')),
            );
          }
          return;
        }
        await audioService.stopPreview();
        try {
          final firstPath = tracks.first.localFilePath;
          final sr = await audioService.getFileSampleRateHz(firstPath);
          final recommended =
              await audioService.getRecommendedBufferSizeFrames();
          await audioService.setOutputQuality(
            sampleRateHz: sr ?? 44100,
            bitDepth: 16,
            bufferSizeFrames: recommended ?? 2048,
            lowLatency: false,
          );
        } catch (_) {}
        await audioService.playAllTracks(tracks);
        // Inicia com ganho mínimo para evitar clique e silêncio perceptível
        final originals = tracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
        const double startGain = 0.35;
        await Future.wait([
          for (int i = 0; i < originals.length; i++)
            audioService.setTrackVolume(i, originals[i] * startGain)
        ]);
        try {
          await audioService.seekPlayAll(sec);
        } catch (_) {}
        // Indica mix global em execução
        ref.read(previewingTrackIdProvider.notifier).state = null;
        setState(() {
          _isPlaying = true;
          _startEpochMs =
              DateTime.now().millisecondsSinceEpoch - (sec * 1000).round();
        });
        ref.read(playheadSecProvider.notifier).state = _playheadSec;
        _startPlayheadTimer();
        // Fade-in curto equal-power
        const int fadeMs = 80;
        const int sSteps = 6;
        final stepDelay2 = Duration(milliseconds: (fadeMs / sSteps).round());
        for (int s = 1; s <= sSteps; s++) {
          final t = s / sSteps;
          final sinv = math.sin((math.pi / 2) * t); // 0..1
          final factor = (startGain + (1 - startGain) * sinv).clamp(startGain, 1.0);
          await Future.wait([
            for (int i = 0; i < originals.length; i++)
              audioService.setTrackVolume(i, originals[i] * factor)
          ]);
          if (s < sSteps) await Future.delayed(stepDelay2);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao ir para o endpoint: $e')),
        );
      }
    }
  }

  Future<void> _renameEndpoint(BuildContext context, Endpoint ep) async {
    final controller = TextEditingController(text: ep.label);
    final newLabel = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Renomear endpoint'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Nome do endpoint'),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Salvar'),
            ),
          ],
        );
      },
    );
    if (newLabel == null) return;
    try {
      final svc = ref.read(endpointServiceProvider);
      await svc.updateLabel(ep.id, newLabel, ep.songId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao renomear: $e')),
        );
      }
    }
  }

  Future<void> _pickColor(BuildContext context, Endpoint ep) async {
    const palette = [
      '#1ABC9C',
      '#2ECC71',
      '#3498DB',
      '#9B59B6',
      '#34495E',
      '#F1C40F',
      '#E67E22',
      '#E74C3C',
      '#95A5A6',
      '#F39C12',
    ];
    final chosen = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Escolher cor'),
          content: SizedBox(
            width: 360,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final hex in palette)
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(hex),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _parseHexColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    );
    if (chosen == null) return;
    try {
      final svc = ref.read(endpointServiceProvider);
      await svc.updateColor(ep.id, chosen, ep.songId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao mudar cor: $e')),
        );
      }
    }
  }

  Future<void> _deleteEndpoint(BuildContext context, Endpoint ep) async {
    try {
      final svc = ref.read(endpointServiceProvider);
      final deleted = await svc.delete(ep.id, ep.songId);
      if (!mounted) return;
      if (deleted != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Endpoint "${deleted.label}" removido'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Desfazer',
              onPressed: () async {
                try {
                  await svc.restore(deleted);
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Falha ao restaurar: $e')),
                    );
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao excluir: $e')),
        );
      }
    }
  }

  Color _parseHexColor(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) {
      h = 'FF$h';
    }
    final v = int.tryParse(h, radix: 16) ?? 0xFF9B59B6;
    return Color(v);
  }
}

class _EndpointTile extends ConsumerWidget {
  final Endpoint endpoint;
  final VoidCallback onGo;
  final VoidCallback onRename;
  final VoidCallback onPickColor;
  final VoidCallback onDelete;
  const _EndpointTile({
    required this.endpoint,
    required this.onGo,
    required this.onRename,
    required this.onPickColor,
    required this.onDelete,
  });

  String _formatMs(int ms) {
    final totalMs = ms.abs();
    final mm = (totalMs ~/ 60000).toString().padLeft(2, '0');
    final ss = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final mmm = (totalMs % 1000).toString().padLeft(3, '0');
    return '$mm:$ss.$mmm';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasMetro = ref.watch(metronomeTrackIdProvider) != null;
    final snap = ref.watch(snapToBeatsProvider);
    final int gridMs = (hasMetro && snap)
        ? (60000 /
                ref.watch(songBpmProvider(endpoint.songId)).clamp(1, 400))
            .round()
        : 100;
    final color = endpoint.colorHex.isNotEmpty
        ? _parseHexColor(endpoint.colorHex)
        : const Color(0xFF9B59B6);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header com cor e informações
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      endpoint.label.isNotEmpty
                          ? endpoint.label
                          : 'Endpoint ${endpoint.id}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatMs(endpoint.timeMs),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color
                                ?.withOpacity(0.7),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Botões de ação
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ActionButton(
                icon: Icons.play_arrow,
                label: 'Ir',
                onPressed: onGo,
              ),
              _ActionButton(
                icon: Icons.edit,
                label: 'Renomear',
                onPressed: onRename,
              ),
              _ActionButton(
                icon: Icons.color_lens,
                label: 'Cor',
                onPressed: onPickColor,
              ),
              _ActionButton(
                icon: Icons.delete_outline,
                label: 'Excluir',
                onPressed: onDelete,
                isDestructive: true,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Setas abaixo de renomear, cor e excluir
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ActionButton(
                icon: Icons.chevron_left,
                label: 'Esq',
                onPressed: () async {
                  try {
                    final svc = ref.read(endpointServiceProvider);
                    final sub = endpoint.timeMs - gridMs;
                    final newTime = sub < 0 ? 0 : sub;
                    await svc.updateTimeMs(
                        endpoint.id, newTime, endpoint.songId);
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Falha ao mover endpoint: $e')),
                    );
                  }
                },
              ),
              const SizedBox(width: 12),
              _ActionButton(
                icon: Icons.chevron_right,
                label: 'Dir',
                onPressed: () async {
                  try {
                    final svc = ref.read(endpointServiceProvider);
                    final newTime = endpoint.timeMs + gridMs;
                    await svc.updateTimeMs(
                        endpoint.id, newTime, endpoint.songId);
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Falha ao mover endpoint: $e')),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _parseHexColor(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) {
      h = 'FF$h';
    }
    final v = int.tryParse(h, radix: 16) ?? 0xFF9B59B6;
    return Color(v);
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool isDestructive;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: color,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontSize: 10,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// _SnapToggle removido: Snap controlado apenas na AppBar, sem campo de BPM manual.
