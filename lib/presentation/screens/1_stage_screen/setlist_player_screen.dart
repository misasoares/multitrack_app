import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/services/setlist_persistence.dart';
import '../../../application/providers/songs_provider.dart';
import '../../../application/providers/device_provider.dart';
import '../../../application/services/i_audio_device_service.dart';
import '../../../domain/models/track_model.dart';
import '../../../application/providers/endpoint_providers.dart';
import '../../../domain/models/endpoint_model.dart';
import '../../widgets/waveform_loader_io.dart'
    if (dart.library.html) '../../widgets/waveform_loader_web.dart' as wf;

class SetlistPlayerScreen extends ConsumerStatefulWidget {
  final SetlistInfo setlist;

  const SetlistPlayerScreen({super.key, required this.setlist});

  @override
  ConsumerState<SetlistPlayerScreen> createState() =>
      _SetlistPlayerScreenState();
}

class _SetlistPlayerScreenState extends ConsumerState<SetlistPlayerScreen> {
  // Fator de largura por música (1.2 => 120% do viewport)
  double _songWidthFactor = 1.5;
  // Fator de amplitude visual da wave (1.0 = padrão). Valores maiores deixam a wave mais alta.
  double _waveAmpFactor = 3.5;
  final Map<int, wf.WaveformData> _waveformCache = {};
  final Map<int, double> _durationCache = {};
  List<double> _timelinePeaks = const [];
  double _timelineDurationSec = 0;
  final GlobalKey _waveformKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  double _viewportWidth = 0.0;

  // Playback state
  bool _isPlaying = false;
  double _playheadPositionSec = 0.0;
  int? _startEpochMs;
  Timer? _playheadTimer;
  int _currentSongIndex = -1;
  final Map<int, List<Track>> _tracksCache = {};

  List<int> get _songIds => widget.setlist.songIds;

  @override
  void initState() {
    super.initState();
    _loadAllWaveforms();
  }

  Future<void> _loadAllWaveforms() async {
    for (final id in _songIds) {
      await _loadWaveformForSong(id);
    }
    _rebuildTimelineWaveform();
  }

  Future<void> _loadWaveformForSong(int songId) async {
    if (_waveformCache.containsKey(songId)) return;
    final song = await ref.read(songWithTracksProvider(songId).future);
    final firstPath = (song?.tracks.isNotEmpty ?? false)
        ? song!.tracks.first.localFilePath
        : null;
    if (firstPath == null || firstPath.isEmpty) {
      _durationCache[songId] = 0;
      return;
    }
    final data = await wf.loadWaveform(firstPath, targetPoints: 500);
    _waveformCache[songId] = data;
    _durationCache[songId] = data.durationSec;
    _rebuildTimelineWaveform();
  }

  void _rebuildTimelineWaveform() {
    final ids = _songIds;
    if (ids.isEmpty) {
      setState(() {
        _timelinePeaks = const [];
        _timelineDurationSec = 0;
      });
      return;
    }
    // Duração total real para controle do áudio/relógio
    final totalDur = ids
        .map((id) =>
            _durationCache[id] ?? _waveformCache[id]?.durationSec ?? 0.0)
        .fold<double>(0.0, (a, b) => a + (b.isFinite ? b : 0.0));
    // Exibir cada música com a mesma largura: usar pontos fixos por música
    const int pointsPerSong = 300;
    final List<double> combined = [];
    for (final id in ids) {
      final src = _waveformCache[id]?.peaks ?? const <double>[];
      final resized = _resizePeaks(src.isEmpty ? [0.0] : src, pointsPerSong);
      combined.addAll(resized);
    }
    setState(() {
      _timelinePeaks = combined;
      _timelineDurationSec = totalDur;
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

  List<double> _computeSongBoundariesSec() {
    if (_songIds.isEmpty) return const [];
    double acc = 0.0;
    final boundaries = <double>[];
    for (final id in _songIds) {
      final dur = _durationCache[id] ?? _waveformCache[id]?.durationSec ?? 0.0;
      if (dur > 0) {
        acc += dur;
        boundaries.add(acc);
      }
    }
    if (boundaries.isNotEmpty &&
        (boundaries.last - _timelineDurationSec).abs() < 1e-6) {
      boundaries.removeLast();
    }
    return boundaries;
  }

  List<String> _buildSongLabels() {
    return List<String>.generate(_songIds.length, (i) => '${i + 1}');
  }

  List<bool> _buildMismatchFlags() {
    // No player: não avaliamos sample rate aqui, mantemos sem aviso
    return List<bool>.filled(_songIds.length, false);
  }

  List<_TimelineEndpoint> _buildCombinedEndpointsTimeline() {
    final ids = _songIds;
    if (ids.isEmpty || _timelineDurationSec <= 0) return const [];

    // Calcula inícios de cada música por soma cumulativa de durações
    // (robusto mesmo quando boundaries estiverem vazios por durações zero)
    final starts = <double>[];
    double acc = 0.0;
    for (int i = 0; i < ids.length; i++) {
      starts.add(acc);
      final id = ids[i];
      final dur = _durationCache[id] ?? _waveformCache[id]?.durationSec ?? 0.0;
      if (dur.isFinite && dur > 0) acc += dur;
    }

    final result = <_TimelineEndpoint>[];
    for (int i = 0; i < ids.length; i++) {
      final songId = ids[i];
      final epsAsync = ref.watch(endpointsBySongProvider(songId));
      final eps =
          epsAsync.maybeWhen(data: (d) => d, orElse: () => const <Endpoint>[]);
      final start = starts[i];
      for (final ep in eps) {
        final sec = (ep.timeMs / 1000.0).clamp(0.0, double.infinity);
        final globalSec = (start + sec).clamp(0.0, _timelineDurationSec);
        result.add(_TimelineEndpoint(
          second: globalSec,
          label: ep.label,
          color: _parseHexColor(ep.colorHex) ?? const Color(0xFF9B59B6),
        ));
      }
    }
    result.sort((a, b) => a.second.compareTo(b.second));
    return result;
  }

  Color? _parseHexColor(String hex) {
    try {
      var h = hex.trim();
      if (h.startsWith('#')) h = h.substring(1);
      if (h.length == 6) {
        final v = int.parse(h, radix: 16);
        return Color(0xFF000000 | v);
      } else if (h.length == 8) {
        final v = int.parse(h, radix: 16);
        return Color(v);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _handleWaveTapAt(
      double tappedSec, List<_TimelineEndpoint> combinedEndpoints) async {
    if (_timelineDurationSec <= 0 || combinedEndpoints.isEmpty) return;
    final boundaries = _computeSongBoundariesSec();
    final songIdx = _songIndexForPosition(tappedSec, boundaries);
    final startSec = songIdx == 0 ? 0.0 : boundaries[songIdx - 1];
    final endSec = songIdx < boundaries.length
        ? boundaries[songIdx]
        : _timelineDurationSec;
    // endpoints within this song
    final eps = combinedEndpoints
        .where((e) => e.second >= startSec && e.second < endSec)
        .toList()
      ..sort((a, b) => a.second.compareTo(b.second));
    if (eps.isEmpty) {
      // Sem endpoints nesta música: snap para o início da música
      await _jumpToGlobalSecWithCrossfade(startSec);
      return;
    }
    // find last endpoint <= tappedSec
    _TimelineEndpoint? chosen;
    for (final e in eps) {
      if (e.second <= tappedSec) {
        chosen = e;
      } else {
        break;
      }
    }
    // Se clicou antes do primeiro endpoint, snap para o início da música
    final targetSec = chosen?.second ?? startSec;

    // Move playhead immediately
    setState(() {
      _playheadPositionSec = targetSec;
      _startEpochMs =
          DateTime.now().millisecondsSinceEpoch - (targetSec * 1000).round();
    });

    // Ensure playback behavior per requirement
    await _jumpToGlobalSecWithCrossfade(targetSec);
  }

  Future<void> _jumpToGlobalSecWithCrossfade(double targetSec) async {
    final audioService = ref.read(audioDeviceServiceProvider);
    final boundaries = _computeSongBoundariesSec();
    final targetSongIdx = _songIndexForPosition(targetSec, boundaries);
    final targetSongId = _songIds[targetSongIdx];
    final targetTracks = await _getSongTracksCached(targetSongId);
    if (targetTracks.isEmpty) return;
    final targetOffset = _offsetInSong(targetSec, targetSongIdx, boundaries);

    // If paused, start playback with a short fade-in at target
    if (!_isPlaying) {
      try {
        await audioService.stopPreview();
      } catch (_) {}
      await _setQualityForTracks(audioService, targetSongId, targetTracks);
      await audioService.playAllTracks(targetTracks);
      // start at reduced gain to avoid click
      final originals =
          targetTracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
      const double startGain = 0.35;
      await Future.wait([
        for (int i = 0; i < originals.length; i++)
          audioService.setTrackVolume(i, originals[i] * startGain)
      ]);
      try {
        await audioService.seekPlayAll(targetOffset);
      } catch (_) {}
      setState(() {
        _isPlaying = true;
        _currentSongIndex = targetSongIdx;
      });
      _startPlayheadTimer();
      // fast fade-in equal-power
      const int fadeMs = 80;
      const int steps = 6;
      final stepDelay = Duration(milliseconds: (fadeMs / steps).round());
      for (int s = 1; s <= steps; s++) {
        final t = s / steps;
        final sinv = math.sin((math.pi / 2) * t);
        final factor =
            (startGain + (1 - startGain) * sinv).clamp(startGain, 1.0);
        await Future.wait([
          for (int i = 0; i < originals.length; i++)
            audioService.setTrackVolume(i, originals[i] * factor)
        ]);
        if (s < steps) await Future.delayed(stepDelay);
      }
      return;
    }

    // Already playing
    if (targetSongIdx == _currentSongIndex) {
      // Crossfade seek within same song
      await _seekWithCrossfade(positionSec: targetOffset, tracks: targetTracks);
    } else {
      // Crossfade between songs: fade out current, switch, fade in new
      // Fade out current song to min gain
      final currentTracks =
          await _getSongTracksCached(_songIds[_currentSongIndex]);
      final currVolumes =
          currentTracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
      const int fadeMs = 80;
      const int steps = 6;
      const double minGain = 0.35;
      final stepDelay = Duration(milliseconds: (fadeMs / steps).round());
      for (int s = 0; s < steps; s++) {
        final t = s / steps;
        final cosv = math.cos((math.pi / 2) * t); // 1..0
        final factor = (minGain + (1 - minGain) * cosv).clamp(minGain, 1.0);
        await Future.wait([
          for (int i = 0; i < currVolumes.length; i++)
            audioService.setTrackVolume(i, currVolumes[i] * factor)
        ]);
        if (s < steps - 1) await Future.delayed(stepDelay);
      }
      try {
        await audioService.stopPreview();
      } catch (_) {}
      await _setQualityForTracks(audioService, targetSongId, targetTracks);
      await audioService.playAllTracks(targetTracks);
      // start at min gain, seek, then fade-in
      final targetVolumes =
          targetTracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
      await Future.wait([
        for (int i = 0; i < targetVolumes.length; i++)
          audioService.setTrackVolume(i, targetVolumes[i] * minGain)
      ]);
      try {
        await audioService.seekPlayAll(targetOffset);
      } catch (_) {}
      setState(() {
        _currentSongIndex = targetSongIdx;
      });
      for (int s = 1; s <= steps; s++) {
        final t = s / steps;
        final sinv = math.sin((math.pi / 2) * t); // 0..1
        final factor = (minGain + (1 - minGain) * sinv).clamp(minGain, 1.0);
        await Future.wait([
          for (int i = 0; i < targetVolumes.length; i++)
            audioService.setTrackVolume(i, targetVolumes[i] * factor)
        ]);
        if (s < steps) await Future.delayed(stepDelay);
      }
    }
  }

  int _xfadeToken = 0;
  Future<void> _seekWithCrossfade({
    required double positionSec,
    required List<Track> tracks,
    int durationMs = 80,
    int steps = 6,
    double minGain = 0.35,
  }) async {
    final audioService = ref.read(audioDeviceServiceProvider);
    if (tracks.isEmpty || durationMs <= 0 || steps <= 0) {
      await audioService.seekPlayAll(positionSec);
      return;
    }
    final original = tracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
    final localToken = ++_xfadeToken;
    final stepDelay = Duration(milliseconds: (durationMs / steps).round());
    bool cancelled() => localToken != _xfadeToken;
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
      await Future.wait([
        for (int ti = 0; ti < original.length; ti++)
          audioService.setTrackVolume(ti, original[ti] * factor)
      ]);
      if (i < steps) {
        await Future.delayed(stepDelay);
        if (cancelled()) return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ids = _songIds;
    // Build combined endpoints timeline (global seconds)
    final combinedEndpoints = _buildCombinedEndpointsTimeline();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.setlist.name),
        centerTitle: true,
      ),
      body: ids.isEmpty
          ? const Center(child: Text('Setlist vazia'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    height: 280,
                    decoration: BoxDecoration(
                      border:
                          Border.all(color: Colors.blueAccent.withOpacity(0.4)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            if (_viewportWidth != constraints.maxWidth) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted)
                                  setState(() =>
                                      _viewportWidth = constraints.maxWidth);
                              });
                            }
                            final songWidthPx =
                                constraints.maxWidth * _songWidthFactor;
                            final contentWidth = _songIds.isEmpty
                                ? constraints.maxWidth
                                : math.max(constraints.maxWidth,
                                    songWidthPx * _songIds.length);
                            return SizedBox(
                              height: 180,
                              width: double.infinity,
                              child: SingleChildScrollView(
                                controller: _scrollController,
                                scrollDirection: Axis.horizontal,
                                physics: const ClampingScrollPhysics(),
                                child: SizedBox(
                                  width: contentWidth,
                                  height: 180,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (details) async {
                                      final local = details.localPosition;
                                      final t = _xToGlobalSec(
                                        x: local.dx,
                                        viewportWidth: constraints.maxWidth,
                                        songWidthPx: songWidthPx,
                                      ).clamp(0.0, _timelineDurationSec);
                                      await _handleWaveTapAt(
                                          t, combinedEndpoints);
                                    },
                                    child: CustomPaint(
                                      key: _waveformKey,
                                      painter: _SetlistWaveformPainter(
                                        peaks: _timelinePeaks,
                                        playheadPositionSec:
                                            _playheadPositionSec,
                                        totalDurationSec: _timelineDurationSec,
                                        boundariesSec:
                                            _computeSongBoundariesSec(),
                                        songLabels: _buildSongLabels(),
                                        mismatchFlags: _buildMismatchFlags(),
                                        endpoints: combinedEndpoints,
                                        equalWidthPerSong: true,
                                        amplitudeScale: _waveAmpFactor,
                                        strokeWidth: 3.0,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: SizedBox(
                              height: 64,
                              width: double.infinity,
                              child: Stack(
                                children: [
                                  // Center: controls (- / play-pause / +)
                                  Align(
                                    alignment: Alignment.center,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton.filledTonal(
                                          onPressed: () =>
                                              _adjustSongWidthFactor(-0.05),
                                          icon: const Icon(Icons.remove),
                                          iconSize: 32,
                                          style: IconButton.styleFrom(
                                            minimumSize: const Size(64, 64),
                                            padding: const EdgeInsets.all(16),
                                            tapTargetSize:
                                                MaterialTapTargetSize.padded,
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        FilledButton.tonalIcon(
                                          onPressed: _togglePlayPause,
                                          icon: Icon(
                                            _isPlaying
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            size: 32,
                                          ),
                                          label: Text(
                                              _isPlaying ? 'Pausar' : 'Tocar'),
                                          style: FilledButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 28),
                                            minimumSize: const Size(160, 64),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        IconButton.filledTonal(
                                          onPressed: () =>
                                              _adjustSongWidthFactor(0.05),
                                          icon: const Icon(Icons.add),
                                          iconSize: 32,
                                          style: IconButton.styleFrom(
                                            minimumSize: const Size(64, 64),
                                            padding: const EdgeInsets.all(16),
                                            tapTargetSize:
                                                MaterialTapTargetSize.padded,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Left: current song name + total duration
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final maxW = constraints.maxWidth * 0.45;
                                          return ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth: maxW,
                                            ),
                                            child: Builder(
                                              builder: (context) {
                                                if (_songIds.isEmpty) {
                                                  return const SizedBox();
                                                }
                                                int idx = _currentSongIndex;
                                                if (idx < 0 || idx >= _songIds.length) {
                                                  idx = 0;
                                                }
                                                final sid = _songIds[idx];
                                                final durSec = _durationCache[sid] ??
                                                    _waveformCache[sid]?.durationSec ??
                                                    0.0;
                                                final durLabel = _formatDuration(durSec);
                                                // elapsed within current song
                                                final boundaries =
                                                    _computeSongBoundariesSec();
                                                final elapsedSec = _offsetInSong(
                                                    _playheadPositionSec,
                                                    idx,
                                                    boundaries);
                                                final elapsedLabel =
                                                    _formatDuration(elapsedSec);
                                                final songAsync = ref.watch(
                                                    songWithTracksProvider(sid));
                                                final style = const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                );
                                                return songAsync.when(
                                                  data: (song) {
                                                    final name =
                                                        song?.name ?? 'Música removida';
                                                    return Text(
                                                      '$name • $elapsedLabel/$durLabel',
                                                      style: style,
                                                      overflow: TextOverflow.ellipsis,
                                                      maxLines: 1,
                                                    );
                                                  },
                                                  loading: () => Text(
                                                    'Carregando… • $elapsedLabel/$durLabel',
                                                    style: style,
                                                    overflow: TextOverflow.ellipsis,
                                                    maxLines: 1,
                                                  ),
                                                  error: (e, st) => Text(
                                                    'Indisponível • $elapsedLabel/$durLabel',
                                                    style: style,
                                                    overflow: TextOverflow.ellipsis,
                                                    maxLines: 1,
                                                  ),
                                                );
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  // Right: total setlist elapsed/total
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final maxW = constraints.maxWidth * 0.45;
                                          final style = const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          );
                                          final totalSec = _timelineDurationSec;
                                          final elapsedGlobal = _playheadPositionSec
                                              .clamp(0.0, totalSec);
                                          final totalLabel = _formatDuration(totalSec);
                                          final elapsedLabel =
                                              _formatDuration(elapsedGlobal);
                                          return ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth: maxW,
                                            ),
                                            child: Text(
                                              'Total • $elapsedLabel/$totalLabel',
                                              style: style,
                                              textAlign: TextAlign.right,
                                              overflow: TextOverflow.ellipsis,
                                              maxLines: 1,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: ids.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final songId = ids[index];
                    final songAsync =
                        ref.watch(songWithTracksProvider(songId));
                    final titleStyle = TextStyle(
                      color: (index == _currentSongIndex)
                          ? Colors.black
                          : null,
                    );
                    final bool isCurrent = index == _currentSongIndex;
                    return Card(
                      elevation: 1,
                      // Use same color as timeline when there is no endpoint
                      color: isCurrent ? const Color(0xFF4FC3F7) : null,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.blueGrey.shade100,
                          child: Text('${index + 1}'),
                        ),
                          title: songAsync.when(
                            data: (song) => Text(
                              song?.name ?? 'Música removida',
                              style: titleStyle,
                            ),
                            loading: () => Text(
                              'Carregando...',
                              style: titleStyle,
                            ),
                            error: (e, st) => Text(
                              'Erro ao carregar música',
                              style: titleStyle,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  String _formatDuration(double seconds) {
    final total = seconds.isFinite ? seconds : 0.0;
    final mins = (total ~/ 60).toString().padLeft(2, '0');
    final secs = (total % 60).round().toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  // ===== Playback helpers =====
  int _songIndexForPosition(double positionSec, List<double> boundaries) {
    if (boundaries.isEmpty) return 0;
    for (int i = 0; i < boundaries.length; i++) {
      if (positionSec < boundaries[i]) return i;
    }
    return boundaries.length; // última música
  }

  double _offsetInSong(
      double positionSec, int songIndex, List<double> boundaries) {
    final startSec = songIndex == 0 ? 0.0 : boundaries[songIndex - 1];
    return (positionSec - startSec).clamp(0.0, double.infinity);
  }

  Future<List<Track>> _getSongTracksCached(int songId) async {
    if (_tracksCache.containsKey(songId)) return _tracksCache[songId]!;
    final song = await ref.read(songWithTracksProvider(songId).future);
    final tracks = song?.tracks.toList() ?? const [];
    _tracksCache[songId] = tracks;
    return tracks;
  }

  Future<void> _setQualityForTracks(
      IAudioDeviceService audioService, int songId, List<Track> tracks) async {
    try {
      final firstPath = tracks.isNotEmpty ? tracks.first.localFilePath : null;
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
  }

  Future<void> _ensurePlaybackForPosition(
      {bool forceSeek = false, bool forceStart = false}) async {
    if ((!_isPlaying && !forceStart) || _songIds.isEmpty) return;
    final audioService = ref.read(audioDeviceServiceProvider);
    final boundaries = _computeSongBoundariesSec();
    final idx = _songIndexForPosition(_playheadPositionSec, boundaries);
    final songId = _songIds[idx];
    final tracks = await _getSongTracksCached(songId);
    if (tracks.isEmpty) return;
    final offsetSec = _offsetInSong(_playheadPositionSec, idx, boundaries);
    if (idx != _currentSongIndex || forceStart) {
      _currentSongIndex = idx;
      try {
        await audioService.stopPreview();
      } catch (_) {}
      await _setQualityForTracks(audioService, songId, tracks);
      await audioService.playAllTracks(tracks);
      await audioService.seekPlayAll(offsetSec);
      // Prepara próxima música
      final nextIndex = _currentSongIndex + 1;
      if (nextIndex < _songIds.length) {
        final nextId = _songIds[nextIndex];
        unawaited(_getSongTracksCached(nextId));
      }
    } else if (forceSeek) {
      await audioService.seekPlayAll(offsetSec);
    }
  }

  void _startPlayheadTimer() {
    _playheadTimer?.cancel();
    _playheadTimer =
        Timer.periodic(const Duration(milliseconds: 33), (_) async {
      if (!_isPlaying) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final start = _startEpochMs ?? now;
      final pos = ((now - start) / 1000.0).clamp(0.0, _timelineDurationSec);
      setState(() {
        _playheadPositionSec = pos;
      });
      await _ensurePlaybackForPosition();
      _autoScrollToCenter();
      if (_playheadPositionSec >= _timelineDurationSec &&
          _timelineDurationSec > 0) {
        // Fim do setlist: pausa
        _togglePlayPause(stopOnly: true);
      }
    });
  }

  void _autoScrollToCenter() {
    if (!_scrollController.hasClients) return;
    final viewport = _viewportWidth > 0
        ? _viewportWidth
        : _scrollController.position.viewportDimension;
    if (viewport <= 0) return;
    final songWidthPx = viewport * _songWidthFactor;
    final playheadX = _secToXGlobal(
      sec: _playheadPositionSec,
      viewportWidth: viewport,
      songWidthPx: songWidthPx,
    );
    final desired = playheadX - viewport / 2;
    final maxOffset = _scrollController.position.maxScrollExtent;
    if (maxOffset <= 0) return;
    final clamped = desired.clamp(0.0, maxOffset);
    final current = _scrollController.offset;
    if ((clamped - current).abs() > 4.0) {
      _scrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    }
  }

  void _adjustSongWidthFactor(double delta) {
    setState(() {
      _songWidthFactor = (_songWidthFactor + delta).clamp(0.5, 3.0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _autoScrollToCenter();
    });
  }

  double _secToXGlobal(
      {required double sec,
      required double viewportWidth,
      required double songWidthPx}) {
    final boundaries = _computeSongBoundariesSec();
    final songIdx = _songIndexForPosition(sec, boundaries);
    final startSec = songIdx == 0 ? 0.0 : boundaries[songIdx - 1];
    final endSec = songIdx < boundaries.length
        ? boundaries[songIdx]
        : _timelineDurationSec;
    final dur = (endSec - startSec).clamp(0.0001, double.infinity);
    final frac = ((sec - startSec) / dur).clamp(0.0, 1.0);
    return (songIdx + frac) * songWidthPx;
  }

  double _xToGlobalSec(
      {required double x,
      required double viewportWidth,
      required double songWidthPx}) {
    if (_songIds.isEmpty) return 0.0;
    if (songWidthPx <= 0) return 0.0;
    final boundaries = _computeSongBoundariesSec();
    // clamp manual para manter tipo int
    int songIdx = (x / songWidthPx).floor();
    final int maxIdx = math.max(0, _songIds.length - 1);
    if (songIdx < 0) songIdx = 0;
    if (songIdx > maxIdx) songIdx = maxIdx;
    final startSec = songIdx == 0 ? 0.0 : boundaries[songIdx - 1];
    final endSec = songIdx < boundaries.length
        ? boundaries[songIdx]
        : _timelineDurationSec;
    final dur = (endSec - startSec).clamp(0.0001, double.infinity);
    final localX = (x - songIdx * songWidthPx).clamp(0.0, songWidthPx);
    final frac = (localX / songWidthPx).clamp(0.0, 1.0);
    return startSec + dur * frac;
  }

  Future<void> _togglePlayPause({bool stopOnly = false}) async {
    final audioService = ref.read(audioDeviceServiceProvider);
    if (_isPlaying || stopOnly) {
      // Pausar
      try {
        await audioService.stopPreview();
      } catch (_) {}
      setState(() {
        // manter posição atual
        _isPlaying = false;
        _startEpochMs = null;
      });
      _playheadTimer?.cancel();
      return;
    }

    // Tocar
    if (_timelineDurationSec <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Nada para tocar: waveform não carregada')),
        );
      }
      return;
    }
    // Ajusta relógio para retomar da posição atual
    _startEpochMs = DateTime.now().millisecondsSinceEpoch -
        (_playheadPositionSec * 1000).round();
    setState(() {
      _isPlaying = true;
    });
    await _ensurePlaybackForPosition(forceSeek: true, forceStart: true);
    _startPlayheadTimer();
  }

  @override
  void dispose() {
    _playheadTimer?.cancel();
    super.dispose();
  }
}

class _SetlistWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final double playheadPositionSec;
  final double totalDurationSec;
  final List<double> boundariesSec;
  final List<String> songLabels;
  final List<bool> mismatchFlags;
  final List<_TimelineEndpoint> endpoints;
  final bool equalWidthPerSong;
  final double amplitudeScale;
  final double strokeWidth;

  _SetlistWaveformPainter({
    required this.peaks,
    required this.playheadPositionSec,
    required this.totalDurationSec,
    required this.boundariesSec,
    required this.songLabels,
    required this.mismatchFlags,
    this.endpoints = const [],
    this.equalWidthPerSong = false,
    this.amplitudeScale = 1.0,
    this.strokeWidth = 2.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1E1E1E);
    canvas.drawRect(Offset.zero & size, bg);
    final midY = size.height * 0.5;
    final ampH = size.height * 0.9 * amplitudeScale;
    final defaultWaveColor = const Color(0xFF4FC3F7);
    final wavePaint = Paint()
      ..color = defaultWaveColor
      ..strokeWidth = strokeWidth;

    // Computa informações por música e helpers de mapeamento
    final int songCount =
        songLabels.isNotEmpty ? songLabels.length : (boundariesSec.length + 1);
    final double songWidthPx =
        songCount > 0 ? (size.width / songCount) : size.width;

    double xForSec(double sec) {
      if (!equalWidthPerSong || songCount <= 0 || totalDurationSec <= 0) {
        final denom = totalDurationSec <= 0 ? 1.0 : totalDurationSec;
        return (sec / denom) * size.width;
      }
      // Mapeia segundos globais para X com largura igual por música
      int idx = 0;
      while (idx < boundariesSec.length && sec >= boundariesSec[idx]) {
        idx++;
      }
      final double startSec = idx == 0 ? 0.0 : boundariesSec[idx - 1];
      final double endSec =
          idx < boundariesSec.length ? boundariesSec[idx] : totalDurationSec;
      final double dur = (endSec - startSec).clamp(0.0001, double.infinity);
      final double frac = ((sec - startSec) / dur).clamp(0.0, 1.0);
      return (idx + frac) * songWidthPx;
    }

    double timeAtIndex(int i) {
      if (!equalWidthPerSong || songCount <= 0 || totalDurationSec <= 0) {
        if (peaks.isEmpty) return 0.0;
        return (i / peaks.length) * totalDurationSec;
      }
      // Número de pontos por música (inteiro), mínimo 1
      int ptsPerSong =
          songCount == 0 ? peaks.length : (peaks.length ~/ songCount);
      if (ptsPerSong < 1) ptsPerSong = 1;
      // Índice de música para o ponto i
      int idxRaw = (i / ptsPerSong).floor();
      final int lastIdx = songCount - 1;
      if (idxRaw < 0) idxRaw = 0;
      if (idxRaw > lastIdx) idxRaw = lastIdx;
      // Índice local dentro da música
      int localIdx = i - idxRaw * ptsPerSong;
      final int localMax = ptsPerSong - 1;
      if (localIdx < 0) localIdx = 0;
      if (localIdx > localMax) localIdx = localMax;
      final double frac =
          (ptsPerSong <= 1) ? 0.0 : (localIdx / (ptsPerSong - 1));
      final double startSec = idxRaw == 0
          ? 0.0
          : (idxRaw - 1) < boundariesSec.length
              ? boundariesSec[idxRaw - 1]
              : (boundariesSec.isNotEmpty ? boundariesSec.last : 0.0);
      final double endSec = idxRaw < boundariesSec.length
          ? boundariesSec[idxRaw]
          : totalDurationSec;
      final double dur = (endSec - startSec).clamp(0.0001, double.infinity);
      return startSec + dur * frac;
    }

    // Build colored segments based on endpoints, constrained per song
    final segments = <_ColorSegment>[];
    if (totalDurationSec > 0 && endpoints.isNotEmpty) {
      // song boundaries define [start, end) for each song
      final songCount = songLabels.isNotEmpty
          ? songLabels.length
          : (boundariesSec.length + 1);
      for (int i = 0; i < songCount; i++) {
        final startSec = i == 0
            ? 0.0
            : (i - 1) < boundariesSec.length
                ? boundariesSec[i - 1]
                : (boundariesSec.isNotEmpty ? boundariesSec.last : 0.0);
        final endSec =
            i < boundariesSec.length ? boundariesSec[i] : totalDurationSec;
        // endpoints that fall inside this song
        final epsInSong = endpoints
            .where((e) => e.second >= startSec && e.second < endSec)
            .toList()
          ..sort((a, b) => a.second.compareTo(b.second));
        for (int j = 0; j < epsInSong.length; j++) {
          final segStart = epsInSong[j].second.clamp(startSec, endSec);
          final segEnd = (j + 1 < epsInSong.length)
              ? epsInSong[j + 1].second.clamp(startSec, endSec)
              : endSec;
          if (segEnd > segStart) {
            segments.add(_ColorSegment(
                startSec: segStart, endSec: segEnd, color: epsInSong[j].color));
          }
        }
      }
      // segments are already in order per song; ensure globally sorted
      segments.sort((a, b) => a.startSec.compareTo(b.startSec));
    }

    // Draw waveform
    if (peaks.isNotEmpty) {
      final stepX = size.width / peaks.length;
      int segIndex = 0;
      double currentSegStart = segIndex < segments.length
          ? segments[segIndex].startSec
          : double.infinity;
      double currentSegEnd = segIndex < segments.length
          ? segments[segIndex].endSec
          : double.infinity;
      Color currentSegColor = segIndex < segments.length
          ? segments[segIndex].color
          : defaultWaveColor;
      for (int i = 0; i < peaks.length; i++) {
        final x = i * stepX;
        final h = ampH * peaks[i].clamp(0.0, 1.0);
        // Map index to time in seconds
        final t = timeAtIndex(i);
        // Advance segment if needed
        while (segIndex < segments.length && t >= currentSegEnd) {
          segIndex++;
          currentSegStart = segIndex < segments.length
              ? segments[segIndex].startSec
              : double.infinity;
          currentSegEnd = segIndex < segments.length
              ? segments[segIndex].endSec
              : double.infinity;
          currentSegColor = segIndex < segments.length
              ? segments[segIndex].color
              : defaultWaveColor;
        }
        // Choose color: colored segment if t within [start, end), else default
        if (segIndex < segments.length &&
            t >= currentSegStart &&
            t < currentSegEnd) {
          if (wavePaint.color != currentSegColor) {
            wavePaint.color = currentSegColor;
          }
        } else {
          if (wavePaint.color != defaultWaveColor) {
            wavePaint.color = defaultWaveColor;
          }
        }
        canvas.drawLine(Offset(x, midY - h), Offset(x, midY + h), wavePaint);
      }
    } else {
      final line = Paint()
        ..color = const Color(0xFF4FC3F7)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), line);
    }

    // Draw endpoints as vertical colored markers with labels
    if (totalDurationSec > 0 && endpoints.isNotEmpty) {
      for (final ep in endpoints) {
        final x = xForSec(ep.second);
        final marker = Paint()
          ..color = ep.color
          ..strokeWidth = 2.0;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), marker);

        // Label near top, positioned to the RIGHT of the marker
        final label = ep.label.isNotEmpty ? ep.label : '';
        if (label.isNotEmpty) {
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            textAlign: TextAlign.left,
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: 120);
          const pad = 4.0;
          final lx = (x + pad).clamp(0.0, size.width - tp.width);
          const ly = 4.0;
          tp.paint(canvas, Offset(lx, ly));
        }
      }
    }

    // Draw song boundaries markers (start of each song and end)
    if (totalDurationSec > 0) {
      final markerPaint = Paint()
        ..color = const Color(0xFF9E9E9E)
        ..strokeWidth = 1.5;
      // Start marker
      canvas.drawLine(Offset(0.5, 0), Offset(0.5, size.height), markerPaint);
      // Song end markers
      for (int i = 0; i < boundariesSec.length; i++) {
        final b = boundariesSec[i];
        final mx = equalWidthPerSong
            ? (i + 1) * songWidthPx
            : (b / totalDurationSec) * size.width;
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
      final sc = songLabels.length;
      for (int i = 0; i < sc; i++) {
        final startSec = i == 0
            ? 0.0
            : (i - 1) < boundariesSec.length
                ? boundariesSec[i - 1]
                : (boundariesSec.isNotEmpty ? boundariesSec.last : 0.0);
        final x = equalWidthPerSong
            ? i * songWidthPx
            : (startSec / totalDurationSec) * size.width;
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
      final sc =
          songLabels.isNotEmpty ? songLabels.length : boundariesSec.length;
      for (int i = 0; i < sc; i++) {
        final startSec = i == 0
            ? 0.0
            : (i - 1) < boundariesSec.length
                ? boundariesSec[i - 1]
                : (boundariesSec.isNotEmpty ? boundariesSec.last : 0.0);
        final endSec =
            i < boundariesSec.length ? boundariesSec[i] : totalDurationSec;
        final segDurSec = (endSec - startSec).clamp(0.0, double.infinity);
        final cx = equalWidthPerSong
            ? (i + 0.5) * songWidthPx
            : ((startSec + endSec) / 2.0 / totalDurationSec) * size.width;
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
      }
    }

    // Draw playhead
    if (totalDurationSec > 0) {
      final playheadX = xForSec(playheadPositionSec);
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
        oldDelegate.mismatchFlags != mismatchFlags ||
        oldDelegate.endpoints != endpoints ||
        oldDelegate.amplitudeScale != amplitudeScale ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _TimelineEndpoint {
  final double second;
  final String label;
  final Color color;
  const _TimelineEndpoint({
    required this.second,
    required this.label,
    required this.color,
  });
}

class _ColorSegment {
  final double startSec;
  final double endSec;
  final Color color;
  const _ColorSegment({
    required this.startSec,
    required this.endSec,
    required this.color,
  });
}
