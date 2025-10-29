import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/audio_providers.dart';
import 'waveform_loader_io.dart'
    if (dart.library.html) 'waveform_loader_web.dart' as wf;

class TrackLevelMeter extends ConsumerStatefulWidget {
  final String filePath;
  final double height;
  final double width;
  final int segments; // quantidade de barras LEDs
  final double volume; // multiplicador de volume atual da faixa
  final double gain; // amplificação da sensação visual
  final double gamma; // curva para expandir valores médios/baixos
  final bool segmented; // true: LEDs; false: barra lisa
  final double attack; // suavização de subida
  final double release; // suavização de descida
  const TrackLevelMeter({
    super.key,
    required this.filePath,
    required this.volume,
    this.height = 160,
    this.width = 18,
    this.segments = 20,
    this.gain = 1.8,
    this.gamma = 0.7,
    this.segmented = true,
    this.attack = 0.6,
    this.release = 0.15,
  });

  @override
  ConsumerState<TrackLevelMeter> createState() => _TrackLevelMeterState();
}

class _TrackLevelMeterState extends ConsumerState<TrackLevelMeter> {
  List<double> _peaks = const [];
  double _durationSec = 0;
  double _smoothedAmp = 0.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TrackLevelMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.filePath.isEmpty) {
      setState(() {
        _peaks = const [];
        _durationSec = 0;
      });
      return;
    }
    try {
      final data = await wf.loadWaveform(widget.filePath, targetPoints: 1000);
      setState(() {
        _peaks = data.peaks;
        _durationSec = data.durationSec;
      });
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    final playhead = ref.watch(playheadSecProvider);
    double amp = _amplitudeAt(playhead) * widget.volume;
    // Amplifica e aplica curva para tornar o VU mais responsivo visualmente
    amp = (amp * widget.gain).clamp(0.0, 1.0);
    amp = math.pow(amp, widget.gamma).toDouble();
    // Pequeno piso para evitar cintilação em silêncio absoluto
    if (amp < 0.02) amp = 0.0;
    // Suavização temporal: ataque/release
    final alpha = amp >= _smoothedAmp ? widget.attack : widget.release;
    _smoothedAmp = _smoothedAmp * (1 - alpha) + amp * alpha;
    final lit = (_smoothedAmp * widget.segments).round();

    return SizedBox(
      height: widget.height,
      width: widget.width,
      child: CustomPaint(
        painter: widget.segmented
            ? _SegmentsPainter(segments: widget.segments, lit: lit)
            : _SmoothBarPainter(ratio: _smoothedAmp.clamp(0.0, 1.0)),
      ),
    );
  }

  double _amplitudeAt(double sec) {
    if (_durationSec <= 0 || _peaks.isEmpty) return 0.0;
    final ratio = (sec / _durationSec).clamp(0.0, 1.0);
    final idx = (ratio * (_peaks.length - 1)).round();
    // pequena janela para suavizar (média de 5 pontos)
    final start = math.max(0, idx - 2);
    final end = math.min(_peaks.length - 1, idx + 2);
    double sum = 0.0;
    int count = 0;
    for (int i = start; i <= end; i++) {
      sum += _peaks[i];
      count++;
    }
    return count > 0 ? (sum / count).clamp(0.0, 1.0) : 0.0;
  }
}

class _SegmentsPainter extends CustomPainter {
  final int segments;
  final int lit;
  _SegmentsPainter({required this.segments, required this.lit});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1E1E1E);
    final border = Paint()
      ..color = Colors.black45
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, bg);
    canvas.drawRect(Offset.zero & size, border);

    final gap = 2.0;
    final segH = (size.height - gap * (segments + 1)) / segments;
    for (int i = 0; i < segments; i++) {
      final y = size.height - (i + 1) * (segH + gap);
      final rect = Rect.fromLTWH(2, y, size.width - 4, segH);
      final color = _colorFor(i);
      final paint = Paint()..color = i < lit ? color : const Color(0xFF2E2E2E);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
      canvas.drawRRect(rrect, paint);
    }
  }

  Color _colorFor(int i) {
    final t = i / math.max(1, segments - 1);
    if (t > 0.85) return Colors.redAccent;
    if (t > 0.6) return const Color(0xFFFFD54F); // amarelo
    return const Color(0xFF66BB6A); // verde
  }

  @override
  bool shouldRepaint(covariant _SegmentsPainter oldDelegate) {
    return oldDelegate.lit != lit || oldDelegate.segments != segments;
  }
}

class _SmoothBarPainter extends CustomPainter {
  final double ratio; // 0..1
  _SmoothBarPainter({required this.ratio});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1E1E1E);
    final border = Paint()
      ..color = Colors.black45
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, bg);
    canvas.drawRect(Offset.zero & size, border);

    final fillH = (size.height - 4) * ratio;
    if (fillH <= 0) return;
    final rect = Rect.fromLTWH(2, size.height - 2 - fillH, size.width - 4, fillH);
    final gradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: const [
        Color(0xFF66BB6A),
        Color(0xFFFFD54F),
        Colors.redAccent,
      ],
      stops: const [0.0, 0.65, 1.0],
    ).createShader(Offset.zero & size);
    final paint = Paint()..shader = gradient;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _SmoothBarPainter oldDelegate) {
    return oldDelegate.ratio != ratio;
  }
}
