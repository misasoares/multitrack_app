import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/songs_provider.dart';
import '../../../application/providers/device_provider.dart';
import '../../../application/providers/audio_providers.dart';
import '../../../application/services/i_audio_device_service.dart';
import '../../../domain/models/song_model.dart';
import '../../../domain/models/track_model.dart';
import '../../../application/services/setlist_persistence.dart';
import '../../widgets/waveform_loader_io.dart'
    if (dart.library.html) '../../widgets/waveform_loader_web.dart' as wf;

class SetlistEditorScreen extends ConsumerStatefulWidget {
  const SetlistEditorScreen({super.key});

  @override
  ConsumerState<SetlistEditorScreen> createState() =>
      _SetlistEditorScreenState();
}

class _SetlistEditorScreenState extends ConsumerState<SetlistEditorScreen> {
  final List<int> _setlistSongIds = [];
  final Map<int, double> _durationCache = {};
  final Map<int, wf.WaveformData> _waveformCache = {};
  bool _isPlaying = false;
  List<double> _timelinePeaks = const [];
  double _timelineDurationSec = 0;
  double _playheadPositionSec = 0;
  final GlobalKey _waveformKey = GlobalKey();
  Timer? _playTimer;
  int _currentSongIndex = 0;
  final Map<int, List<Track>> _songTracksCache = {};
  final Map<int, int> _songSampleRateHzCache = {};
  final Map<int, bool> _songSampleRateMismatch = {};

  Future<double> _getSongDurationSec(int songId) async {
    if (_durationCache.containsKey(songId)) return _durationCache[songId] ?? 0;
    final song = await ref.read(songWithTracksProvider(songId).future);
    final firstPath = (song?.tracks.isNotEmpty ?? false)
        ? song!.tracks.first.localFilePath
        : null;
    if (firstPath == null || firstPath.isEmpty) {
      _durationCache[songId] = 0;
      return 0;
    }
    final data = await wf.loadWaveform(firstPath, targetPoints: 500);
    _waveformCache[songId] = data;
    _durationCache[songId] = data.durationSec;
    _rebuildTimelineWaveform();
    return data.durationSec;
  }

  String _formatDuration(double sec) {
    final total = sec.isFinite ? sec.round() : 0;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _playTimeline() async {
    if (_setlistSongIds.isEmpty) return;
    try {
      final audioService = ref.read(audioDeviceServiceProvider);
      // Determina índice da música atual e offset dentro dela
      final boundaries = _computeSongBoundariesSec();
      _currentSongIndex =
          _songIndexForPosition(_playheadPositionSec, boundaries);
      final offsetSec =
          _offsetInSong(_playheadPositionSec, _currentSongIndex, boundaries);
      final songId = _setlistSongIds[_currentSongIndex];
      final tracks = await _getSongTracksCached(songId);
      if (tracks.isEmpty) return;
      await _setQualityForTracks(audioService, songId, tracks);
      await audioService.stopPreview();
      await audioService.playAllTracks(tracks);
      await audioService.seekPlayAll(offsetSec);
      setState(() => _isPlaying = true);
      _startPlayTimer();

      // Pré-carrega a próxima música (se existir)
      final nextIndex = _currentSongIndex + 1;
      if (nextIndex < _setlistSongIds.length) {
        final nextId = _setlistSongIds[nextIndex];
        unawaited(_getSongTracksCached(nextId).then((nextTracks) async {
          await audioService.prepareTracks(nextTracks);
        }));
      }
    } catch (_) {
      // swallow errors gracefully for MVP
    }
  }

  Future<void> _pauseTimeline() async {
    try {
      final audioService = ref.read(audioDeviceServiceProvider);
      await audioService.stopPreview();
    } catch (_) {}
    setState(() => _isPlaying = false);
    _playTimer?.cancel();
  }

  void _rebuildTimelineWaveform() {
    // Recalcula picos combinados da timeline a partir do cache
    final ids =
        _setlistSongIds.where((id) => _waveformCache.containsKey(id)).toList();
    if (ids.isEmpty) {
      setState(() {
        _timelinePeaks = const [];
        _timelineDurationSec = 0;
      });
      return;
    }
    final durations = ids.map((id) => _waveformCache[id]!.durationSec).toList();
    final totalDur =
        durations.fold<double>(0.0, (a, b) => a + (b.isFinite ? b : 0.0));
    const totalPoints = 1000;
    final List<double> combined = [];
    for (int i = 0; i < ids.length; i++) {
      final data = _waveformCache[ids[i]]!;
      final src = data.peaks;
      int pointsForSong;
      if (totalDur <= 0) {
        pointsForSong = (totalPoints / ids.length).floor();
      } else {
        pointsForSong = ((data.durationSec / totalDur) * totalPoints).floor();
      }
      pointsForSong = pointsForSong.clamp(20, totalPoints);
      final resized = _resizePeaks(src, pointsForSong);
      combined.addAll(resized);
    }
    setState(() {
      _timelinePeaks = combined;
      _timelineDurationSec = totalDur;
      // Mantém o playhead dentro do novo range
      _playheadPositionSec = _playheadPositionSec.clamp(0.0, totalDur);
    });
  }

  List<double> _resizePeaks(List<double> src, int target) {
    if (src.isEmpty || target <= 0) return List<double>.filled(target, 0.0);
    if (src.length == target) return List<double>.from(src);
    final out = <double>[];
    for (int i = 0; i < target; i++) {
      final t = i / (target - 1);
      final idx = (t * (src.length - 1)).round();
      out.add(src[idx].clamp(0.0, 1.0));
    }
    return out;
  }

  void _onWaveformTap(Offset localPosition) {
    _updatePlayheadFromPosition(localPosition);
  }

  void _onWaveformDrag(Offset localPosition) {
    _updatePlayheadFromPosition(localPosition);
  }

  void _updatePlayheadFromPosition(Offset localPosition) {
    if (_timelineDurationSec <= 0) return;
    // Usa o tamanho real da área do waveform através de GlobalKey
    final box = _waveformKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final containerWidth = box.size.width;
    final localX = localPosition.dx.clamp(0.0, containerWidth);
    final normalizedX = (localX / containerWidth).clamp(0.0, 1.0);
    double newPosition = normalizedX * _timelineDurationSec;

    // Snap para limites entre músicas (se existirem)
    final boundariesSec = _computeSongBoundariesSec();
    if (boundariesSec.isNotEmpty) {
      // Converte boundaries para posição X e verifica proximidade em pixels
      final thresholdPx = 8.0;
      double snapped = newPosition;
      for (final b in boundariesSec) {
        final bx = (b / _timelineDurationSec) * containerWidth;
        if ((localX - bx).abs() <= thresholdPx) {
          snapped = b;
          break;
        }
      }
      newPosition = snapped;
    }

    setState(() {
      _playheadPositionSec = newPosition.clamp(0.0, _timelineDurationSec);
    });

    // Publica playhead global para sincronizar outras UIs
    ref.read(playheadSecProvider.notifier).state = _playheadPositionSec;

    // Faz seek no serviço de áudio se estiver tocando
    try {
      final audioService = ref.read(audioDeviceServiceProvider);
      _ensurePlaybackForPosition(forceSeek: true);
    } catch (_) {}
  }

  List<double> _computeSongBoundariesSec() {
    if (_setlistSongIds.isEmpty) return const [];
    double acc = 0.0;
    final boundaries = <double>[];
    for (final id in _setlistSongIds) {
      final dur = _durationCache[id] ?? _waveformCache[id]?.durationSec ?? 0.0;
      if (dur > 0) {
        acc += dur;
        boundaries.add(acc);
      }
    }
    // Remove o último limite se igual à duração total (evita snap no fim)
    if (boundaries.isNotEmpty &&
        (boundaries.last - _timelineDurationSec).abs() < 1e-6) {
      boundaries.removeLast();
    }
    return boundaries;
  }

  List<String> _buildSongLabels() {
    // Por ora, usamos apenas índices (1-based).
    // Futuro: preencher com nomes das músicas via cache/título.
    return List<String>.generate(_setlistSongIds.length, (i) => '${i + 1}');
  }

  int _songIndexForPosition(double posSec, List<double> boundaries) {
    if (_setlistSongIds.isEmpty) return 0;
    for (int i = 0; i < boundaries.length; i++) {
      if (posSec < boundaries[i]) return i;
    }
    return _setlistSongIds.length - 1;
  }

  double _offsetInSong(double posSec, int index, List<double> boundaries) {
    final prevBoundary = index == 0 ? 0.0 : boundaries[index - 1];
    return (posSec - prevBoundary).clamp(0.0, double.infinity);
  }

  List<bool> _buildMismatchFlags() {
    return List<bool>.generate(
      _setlistSongIds.length,
      (i) => _songSampleRateMismatch[_setlistSongIds[i]] == true,
    );
  }

  Future<void> _ensurePlaybackForPosition({bool forceSeek = false}) async {
    if (!_isPlaying || _setlistSongIds.isEmpty) return;
    final audioService = ref.read(audioDeviceServiceProvider);
    final boundaries = _computeSongBoundariesSec();
    final idx = _songIndexForPosition(_playheadPositionSec, boundaries);
    final songId = _setlistSongIds[idx];
    final tracks = await _getSongTracksCached(songId);
    if (tracks.isEmpty) return;
    final offsetSec = _offsetInSong(_playheadPositionSec, idx, boundaries);
    if (idx != _currentSongIndex) {
      _currentSongIndex = idx;
      try {
        await audioService.stopPreview();
      } catch (_) {}
      await _setQualityForTracks(audioService, songId, tracks);
      await audioService.playAllTracks(tracks);
      await audioService.seekPlayAll(offsetSec);
      // Pré-carrega próxima música ao trocar
      final nextIndex = _currentSongIndex + 1;
      if (nextIndex < _setlistSongIds.length) {
        final nextId = _setlistSongIds[nextIndex];
        unawaited(_getSongTracksCached(nextId).then((nextTracks) async {
          await audioService.prepareTracks(nextTracks);
        }));
      }
    } else if (forceSeek) {
      await audioService.seekPlayAll(offsetSec);
    }
  }

  Future<List<Track>> _getSongTracksCached(int songId) async {
    final cached = _songTracksCache[songId];
    if (cached != null) return cached;
    final song = await ref.read(songWithTracksProvider(songId).future);
    final tracks = song?.tracks.toList() ?? <Track>[];
    _songTracksCache[songId] = tracks;
    // Pré-computa sample rate do primeiro arquivo, se possível
    unawaited(_computeAndCacheSampleRate(songId, tracks));
    // Verifica divergência de sample rate entre as tracks da mesma música
    unawaited(_computeSampleRateMismatch(songId, tracks));
    return tracks;
  }

  Future<void> _computeAndCacheSampleRate(int songId, List<Track> tracks) async {
    if (tracks.isEmpty) return;
    if (_songSampleRateHzCache.containsKey(songId)) return;
    final audioService = ref.read(audioDeviceServiceProvider);
    final firstPath = tracks.first.localFilePath;
    final sr = await audioService.getFileSampleRateHz(firstPath);
    if (sr != null && sr > 0) {
      _songSampleRateHzCache[songId] = sr;
    }
  }

  Future<void> _computeSampleRateMismatch(int songId, List<Track> tracks) async {
    if (tracks.isEmpty) return;
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
    final mismatch = rates.length > 1;
    if (mounted) {
      setState(() {
        _songSampleRateMismatch[songId] = mismatch;
      });
    } else {
      _songSampleRateMismatch[songId] = mismatch;
    }
  }

  Future<void> _setQualityForTracks(
    IAudioDeviceService audioService,
    int songId,
    List<Track> tracks,
  ) async {
    // usa cache se disponível; senão tenta ler do primeiro arquivo
    int sampleRate = _songSampleRateHzCache[songId] ?? 0;
    if (sampleRate <= 0 && tracks.isNotEmpty) {
      final sr = await audioService.getFileSampleRateHz(tracks.first.localFilePath);
      sampleRate = sr ?? 44100;
      _songSampleRateHzCache[songId] = sampleRate;
    }
    // tenta obter buffer recomendado pelo dispositivo
    final recommended = await audioService.getRecommendedBufferSizeFrames();
    final bufferFrames = recommended ?? 2048;
    // aplica configuração com buffer maior e sem baixa latência
    await audioService.setOutputQuality(
      sampleRateHz: sampleRate,
      bitDepth: 16,
      bufferSizeFrames: bufferFrames,
      lowLatency: false,
    );
  }

  void _startPlayTimer() {
    _playTimer?.cancel();
    _playTimer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      if (!_isPlaying) return;
      final newPos =
          (_playheadPositionSec + 0.05).clamp(0.0, _timelineDurationSec);
      setState(() {
        _playheadPositionSec = newPos;
      });
      ref.read(playheadSecProvider.notifier).state = newPos;
      await _ensurePlaybackForPosition(forceSeek: false);
      // Pré-carrega próxima música quando se aproxima do limite (< 2s)
      final boundaries = _computeSongBoundariesSec();
      final idx = _songIndexForPosition(newPos, boundaries);
      final nextIndex = idx + 1;
      if (nextIndex < _setlistSongIds.length) {
        final currentEnd = boundaries[idx];
        if ((currentEnd - newPos) <= 2.0) {
          final nextId = _setlistSongIds[nextIndex];
          unawaited(_getSongTracksCached(nextId).then((nextTracks) async {
            final audioService = ref.read(audioDeviceServiceProvider);
            await audioService.prepareTracks(nextTracks);
          }));
        }
      }
      if (newPos >= _timelineDurationSec) {
        await _pauseTimeline();
      }
    });
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncSongs = ref.watch(songsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Criar Setlist'),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: _isPlaying ? 'Pausar' : 'Reproduzir',
                  iconSize: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  constraints: const BoxConstraints(minWidth: 60, minHeight: 48),
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                  ),
                  onPressed: () =>
                      _isPlaying ? _pauseTimeline() : _playTimeline(),
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: 'Salvar setlist',
                  iconSize: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  constraints: const BoxConstraints(minWidth: 60, minHeight: 48),
                  icon: const Icon(Icons.save_alt),
                  onPressed: _onSaveSetlistPressed,
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: DragTarget<int>(
              onWillAccept: (data) => data != null,
              onAccept: (songId) {
                setState(() {
                  if (!_setlistSongIds.contains(songId)) {
                    _setlistSongIds.add(songId);
                  }
                });
                _rebuildTimelineWaveform();
              },
              builder: (context, candidate, rejected) {
                return Container(
                  height: 200,
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: Colors.blueAccent.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(8),
                    color: candidate.isNotEmpty
                        ? Colors.blueAccent.withOpacity(0.08)
                        : Colors.transparent,
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 80,
                        width: double.infinity,
                        child: GestureDetector(
                          key: _waveformKey,
                          onTapDown: (details) =>
                              _onWaveformTap(details.localPosition),
                          onPanUpdate: (details) =>
                              _onWaveformDrag(details.localPosition),
                          child: CustomPaint(
                            painter: _SetlistWaveformPainter(
                              peaks: _timelinePeaks,
                              playheadPositionSec: _playheadPositionSec,
                              totalDurationSec: _timelineDurationSec,
                              boundariesSec: _computeSongBoundariesSec(),
                              songLabels: _buildSongLabels(),
                              mismatchFlags: _buildMismatchFlags(),
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: Row(
                          children: [
                            if (_setlistSongIds.isEmpty)
                              const Expanded(
                                child: Center(
                                  child: Text(
                                      'Arraste músicas aqui para montar a timeline'),
                                ),
                              )
                            else
                              Expanded(
                                child: ReorderableListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _setlistSongIds.length,
                                  onReorder: (oldIndex, newIndex) {
                                    setState(() {
                                      if (newIndex > oldIndex) newIndex -= 1;
                                      final moved =
                                          _setlistSongIds.removeAt(oldIndex);
                                      _setlistSongIds.insert(newIndex, moved);
                                    });
                                    _rebuildTimelineWaveform();
                                  },
                                  itemBuilder: (context, idx) {
                                    final songId = _setlistSongIds[idx];
                                    final songsValue = asyncSongs.maybeWhen(
                                      data: (list) => list,
                                      orElse: () => const <Song>[],
                                    );
                                    final song = songsValue.firstWhere(
                                      (s) => s.id == songId,
                                      orElse: () =>
                                          Song()..name = 'Música $songId',
                                    );
                                    return Container(
                                      key: ValueKey(songId),
                                      padding: const EdgeInsets.only(right: 8),
                                      child: FutureBuilder<double>(
                                        future: _getSongDurationSec(songId),
                                        builder: (context, snap) {
                                          final dur = snap.data ?? 0;
                                          return Card(
                                            elevation: 1,
                                            child: Container(
                                              width: 220,
                                              padding: const EdgeInsets.all(8),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      ReorderableDragStartListener(
                                                        index: idx,
                                                        child: const Padding(
                                                          padding:
                                                              EdgeInsets.only(
                                                                  right: 6),
                                                          child: Icon(
                                                            Icons.drag_handle,
                                                            size: 18,
                                                          ),
                                                        ),
                                                      ),
                                                      Expanded(
                                                        child: Text(
                                                          song.name,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: const TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold),
                                                        ),
                                                      ),
                                                      IconButton(
                                                        tooltip: 'Remover',
                                                        icon: const Icon(
                                                            Icons.close,
                                                            size: 18),
                                                        padding:
                                                            EdgeInsets.zero,
                                                        constraints:
                                                            const BoxConstraints(
                                                          minWidth: 24,
                                                          minHeight: 24,
                                                        ),
                                                        onPressed: () {
                                                          setState(() {
                                                            _setlistSongIds
                                                                .removeAt(idx);
                                                          });
                                                          _rebuildTimelineWaveform();
                                                        },
                                                      ),
                                                    ],
                                                  ),
                                                  Text(
                                                    'Duração: ${_formatDuration(dur)}',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.grey[600],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
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
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: asyncSongs.when(
              data: (songs) {
                if (songs.isEmpty) {
                  return const Center(child: Text('Nenhuma música disponível'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return LongPressDraggable<int>(
                      data: song.id,
                      feedback: Material(
                        color: Colors.transparent,
                        child: Chip(
                          label: Text(song.name),
                          backgroundColor: Colors.blueAccent,
                          labelStyle: const TextStyle(color: Colors.white),
                        ),
                      ),
                      child: Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.blue,
                            child: Icon(Icons.music_note, color: Colors.white),
                          ),
                          title: Text(song.name),
                          subtitle: FutureBuilder<double>(
                            future: _getSongDurationSec(song.id),
                            builder: (context, snap) {
                              final dur = snap.data ?? 0;
                              return Text('Duração: ${_formatDuration(dur)}');
                            },
                          ),
                          trailing: IconButton(
                            tooltip: 'Adicionar à timeline',
                            icon: const Icon(Icons.add),
                            onPressed: () {
                              setState(() {
                                if (!_setlistSongIds.contains(song.id)) {
                                  _setlistSongIds.add(song.id);
                                }
                              });
                            },
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) =>
                  Center(child: Text('Erro ao carregar músicas: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

extension on _SetlistEditorScreenState {
  Future<void> _onSaveSetlistPressed() async {
    if (_setlistSongIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Adicione músicas antes de salvar o setlist')),
      );
      return;
    }
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Salvar setlist'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Nome do setlist',
              hintText: 'Ex.: Show de sábado',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Salvar'),
            ),
          ],
        );
      },
    );
    try {
      final saved = await SetlistPersistence.saveSetlist(
        name: name ?? '',
        songIds: List<int>.from(_setlistSongIds),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Setlist salvo em ${saved.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao salvar setlist: $e')),
      );
    }
  }
}

class _SetlistWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final double playheadPositionSec;
  final double totalDurationSec;
  final List<double> boundariesSec;
  final List<String> songLabels;
  final List<bool> mismatchFlags;

  _SetlistWaveformPainter({
    required this.peaks,
    required this.playheadPositionSec,
    required this.totalDurationSec,
    required this.boundariesSec,
    required this.songLabels,
    required this.mismatchFlags,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1E1E1E);
    canvas.drawRect(Offset.zero & size, bg);
    final midY = size.height * 0.5;
    final ampH = size.height * 0.9;
    final wavePaint = Paint()
      ..color = const Color(0xFF4FC3F7)
      ..strokeWidth = 2;

    // Draw waveform
    if (peaks.isNotEmpty) {
      final stepX = size.width / peaks.length;
      for (int i = 0; i < peaks.length; i++) {
        final x = i * stepX;
        final h = ampH * peaks[i].clamp(0.0, 1.0);
        canvas.drawLine(Offset(x, midY - h), Offset(x, midY + h), wavePaint);
      }
    } else {
      final line = Paint()
        ..color = const Color(0xFF4FC3F7)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), line);
    }

    // Draw song boundaries markers (start of each song and end)
    if (totalDurationSec > 0) {
      final markerPaint = Paint()
        ..color = const Color(0xFF9E9E9E)
        ..strokeWidth = 1.5;
      // Start marker
      canvas.drawLine(Offset(0.5, 0), Offset(0.5, size.height), markerPaint);
      // Song end markers
      for (final b in boundariesSec) {
        final mx = (b / totalDurationSec) * size.width;
        canvas.drawLine(Offset(mx, 0), Offset(mx, size.height), markerPaint);
      }
      // End of timeline marker
      canvas.drawLine(Offset(size.width - 0.5, 0),
          Offset(size.width - 0.5, size.height), markerPaint);
    }

    // Top ticks and song index/name labels at each song start
    if (totalDurationSec > 0 && songLabels.isNotEmpty) {
      final tickPaint = Paint()
        ..color = const Color(0xFFBDBDBD)
        ..strokeWidth = 1.0;
      final labelStyle = const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      );
      final topPadding = 2.0;
      final tickHeight = 8.0;
      final songCount = songLabels.length;
      for (int i = 0; i < songCount; i++) {
        final startSec = i == 0 ? 0.0 : boundariesSec[i - 1];
        final x = (startSec / totalDurationSec) * size.width;
        // tick
        canvas.drawLine(Offset(x, 0), Offset(x, tickHeight), tickPaint);
        // label
        final label = songLabels[i];
        final tp = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        var lx = x + 2.0;
        if (lx + tp.width > size.width - 4.0) {
          lx = (size.width - tp.width - 4.0).clamp(0.0, size.width - tp.width);
        }
        tp.paint(canvas, Offset(lx, topPadding));
      }
    }

    // Per-song duration pills centered within each segment
    if (totalDurationSec > 0 && boundariesSec.isNotEmpty) {
      final labelStyle = const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      );
      final pillPadding = 6.0;
      final y = 18.0; // below top ticks/labels
      final songCount =
          songLabels.isNotEmpty ? songLabels.length : boundariesSec.length;
      for (int i = 0; i < songCount; i++) {
        final startSec = i == 0 ? 0.0 : boundariesSec[i - 1];
        final endSec =
            i < boundariesSec.length ? boundariesSec[i] : totalDurationSec;
        final segDurSec = (endSec - startSec).clamp(0.0, double.infinity);
        final segMidSec = (startSec + endSec) / 2.0;
        final cx = (segMidSec / totalDurationSec) * size.width;
        final total = segDurSec.round();
        final mm = (total ~/ 60).toString().padLeft(2, '0');
        final ss = (total % 60).toString().padLeft(2, '0');
        final label = '$mm:$ss';
        final tp = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        final pillWidth = tp.width + pillPadding * 2;
        final pillHeight = tp.height + 2;
        var pillX = (cx - pillWidth / 2).clamp(0.0, size.width - pillWidth);
        final pillRect = Rect.fromLTWH(pillX, y, pillWidth, pillHeight);
        final pillR =
            RRect.fromRectAndRadius(pillRect, const Radius.circular(8));
        final pillBg = Paint()..color = const Color(0xCC424242);
        canvas.drawRRect(pillR, pillBg);
        tp.paint(canvas, Offset(pillX + pillPadding, y));

        // Warning badge for sample-rate mismatch in this segment
        final hasWarn = mismatchFlags.isNotEmpty && i < mismatchFlags.length && mismatchFlags[i];
        if (hasWarn) {
          const badgeText = 'Taxas diferentes';
          final warnStyle = const TextStyle(
            color: Colors.black,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          );
          final wtp = TextPainter(
            text: TextSpan(text: badgeText, style: warnStyle),
            textDirection: TextDirection.ltr,
          )..layout();
          final badgePadding = 6.0;
          final bw = wtp.width + badgePadding * 2;
          final bh = wtp.height + 2;
          // place slightly below the duration pill
          var bx = (cx - bw / 2).clamp(0.0, size.width - bw);
          final by = y + pillHeight + 4.0;
          final bRect = Rect.fromLTWH(bx, by, bw, bh);
          final bR = RRect.fromRectAndRadius(bRect, const Radius.circular(6));
          final bBg = Paint()..color = const Color(0xFFFFF176); // amber 300
          canvas.drawRRect(bR, bBg);
          wtp.paint(canvas, Offset(bx + badgePadding, by));
        }
      }
    }

    // Draw playhead
    if (totalDurationSec > 0) {
      final playheadX = (playheadPositionSec / totalDurationSec) * size.width;
      final playheadPaint = Paint()
        ..color = const Color(0xFFFF5722)
        ..strokeWidth = 3;

      // Draw vertical line
      canvas.drawLine(
        Offset(playheadX, 0),
        Offset(playheadX, size.height),
        playheadPaint,
      );

      // Draw playhead handle (small circle at top)
      final handlePaint = Paint()
        ..color = const Color(0xFFFF5722)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(playheadX, 8),
        6,
        handlePaint,
      );

      // Draw time label near the playhead
      final total =
          playheadPositionSec.isFinite ? playheadPositionSec.round() : 0;
      final mm = (total ~/ 60).toString().padLeft(2, '0');
      final ss = (total % 60).toString().padLeft(2, '0');
      final label = '$mm:$ss';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final padding = 6.0;
      final pillWidth = tp.width + padding * 2;
      final pillHeight = tp.height + 2;
      double pillX = playheadX - pillWidth / 2;
      pillX = pillX.clamp(0.0, size.width - pillWidth);
      final pillY = 2.0;
      final pillRect = Rect.fromLTWH(pillX, pillY, pillWidth, pillHeight);
      final pillR = RRect.fromRectAndRadius(pillRect, const Radius.circular(8));
      final pillBg = Paint()..color = const Color(0xCC424242);
      canvas.drawRRect(pillR, pillBg);
      tp.paint(canvas, Offset(pillX + padding, pillY));
    }

    // Draw total duration label at top-right
    if (totalDurationSec > 0) {
      final total = totalDurationSec.isFinite ? totalDurationSec.round() : 0;
      final mm = (total ~/ 60).toString().padLeft(2, '0');
      final ss = (total % 60).toString().padLeft(2, '0');
      final label = 'Total: $mm:$ss';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final padding = 6.0;
      final pillWidth = tp.width + padding * 2;
      final pillHeight = tp.height + 2;
      final pillX =
          (size.width - pillWidth - 6.0).clamp(0.0, size.width - pillWidth);
      final pillY = 2.0;
      final pillRect = Rect.fromLTWH(pillX, pillY, pillWidth, pillHeight);
      final pillR = RRect.fromRectAndRadius(pillRect, const Radius.circular(8));
      final pillBg = Paint()..color = const Color(0xCC424242);
      canvas.drawRRect(pillR, pillBg);
      tp.paint(canvas, Offset(pillX + padding, pillY));
    }
  }

  @override
  bool shouldRepaint(covariant _SetlistWaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.playheadPositionSec != playheadPositionSec ||
        oldDelegate.totalDurationSec != totalDurationSec ||
        oldDelegate.boundariesSec != boundariesSec ||
        oldDelegate.songLabels != songLabels ||
        oldDelegate.mismatchFlags != mismatchFlags;
  }
}