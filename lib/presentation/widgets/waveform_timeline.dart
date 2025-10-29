import 'dart:async';
import 'package:flutter/material.dart';
import 'waveform_loader_io.dart'
    if (dart.library.html) 'waveform_loader_web.dart' as wf;

class WaveformTimeline extends StatefulWidget {
  final String? filePath; // Use first track path or null for placeholder
  final bool isPlaying;
  final int? startEpochMs; // when playback started
  final double height;
  final ValueChanged<double>? onSeek; // seconds
  const WaveformTimeline({
    super.key,
    required this.filePath,
    required this.isPlaying,
    required this.startEpochMs,
    this.height = 120,
    this.onSeek,
  });

  @override
  State<WaveformTimeline> createState() => _WaveformTimelineState();
}

class _WaveformTimelineState extends State<WaveformTimeline> {
  List<double> _peaks = const [];
  int _sampleRate = 44100;
  int _channels = 2;
  int _bitsPerSample = 16;
  int _dataBytes = 0;
  double _durationSec = 0;
  Timer? _timer;
  double _elapsedSec = 0;

  @override
  void initState() {
    super.initState();
    _loadWaveform();
    _setupTimer();
  }

  @override
  void didUpdateWidget(covariant WaveformTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _loadWaveform();
    }
    _setupTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _setupTimer() {
    _timer?.cancel();
    if (widget.isPlaying && widget.startEpochMs != null) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsed = (now - (widget.startEpochMs ?? now)) / 1000.0;
        setState(() {
          _elapsedSec = elapsed;
        });
      });
    }
  }

  Future<void> _loadWaveform() async {
    setState(() {
      _peaks = const [];
      _durationSec = 0;
      _sampleRate = 44100;
      _channels = 2;
      _bitsPerSample = 16;
      _dataBytes = 0;
    });

    final path = widget.filePath;
    if (path == null || path.isEmpty) return;
    try {
      final data = await wf.loadWaveform(path, targetPoints: 1000);
      setState(() {
        _peaks = data.peaks;
        _sampleRate = data.sampleRate;
        _channels = data.channels;
        _bitsPerSample = data.bitsPerSample;
        _dataBytes = data.dataBytes;
        _durationSec = data.durationSec;
      });
    } catch (_) {
      // ignore errors
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          final box = context.findRenderObject() as RenderBox?;
          final size = box?.size ?? Size.zero;
          if (size.width <= 0 || _durationSec <= 0) return;
          final dx = details.localPosition.dx.clamp(0.0, size.width);
          final ratio = (dx / size.width).clamp(0.0, 1.0);
          final posSec = ratio * _durationSec;
          setState(() {
            _elapsedSec = posSec;
          });
          widget.onSeek?.call(posSec);
        },
        onHorizontalDragStart: (details) {
          final box = context.findRenderObject() as RenderBox?;
          final size = box?.size ?? Size.zero;
          if (size.width <= 0 || _durationSec <= 0) return;
          final dx = details.localPosition.dx.clamp(0.0, size.width);
          final ratio = (dx / size.width).clamp(0.0, 1.0);
          final posSec = ratio * _durationSec;
          setState(() {
            _elapsedSec = posSec;
          });
          widget.onSeek?.call(posSec);
        },
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          final size = box?.size ?? Size.zero;
          if (size.width <= 0 || _durationSec <= 0) return;
          final dx = details.localPosition.dx.clamp(0.0, size.width);
          final ratio = (dx / size.width).clamp(0.0, 1.0);
          final posSec = ratio * _durationSec;
          setState(() {
            _elapsedSec = posSec;
          });
          widget.onSeek?.call(posSec);
        },
        child: CustomPaint(
          painter: _WaveformPainter(
            peaks: _peaks,
            elapsedSec: _elapsedSec,
            durationSec: _durationSec,
          ),
        ),
      ),
    );
  }

  static String _formatTime(double sec) {
    final s = sec.isFinite ? sec : 0;
    final total = s.floor();
    final mm = (total ~/ 60).toString().padLeft(2, '0');
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> peaks;
  final double elapsedSec;
  final double durationSec;
  _WaveformPainter(
      {required this.peaks,
      required this.elapsedSec,
      required this.durationSec});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1E1E1E);
    canvas.drawRect(Offset.zero & size, bg);

    // Draw waveform centerline and peaks
    final midY = size.height * 0.5; // leave space for labels
    final ampH = size.height * 1.9;
    final wavePaint = Paint()
      ..color = const Color(0xFF4FC3F7)
      ..strokeWidth = 2;
    if (peaks.isNotEmpty) {
      final stepX = size.width / peaks.length;
      for (int i = 0; i < peaks.length; i++) {
        final x = i * stepX;
        final h = ampH * peaks[i].clamp(0.0, 1.0);
        canvas.drawLine(Offset(x, midY - h), Offset(x, midY + h), wavePaint);
      }
    } else {
      // Placeholder line
      final line = Paint()
        ..color = const Color(0xFF4FC3F7)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), line);
    }

    // Draw playhead
    double ratio = 0.0;
    if (durationSec > 0 && elapsedSec >= 0) {
      ratio = (elapsedSec / durationSec).clamp(0.0, 1.0);
    }
    final xPlay = ratio * size.width;
    final playPaint = Paint()
      ..color = const Color(0xFFFF4081)
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(xPlay, 0), Offset(xPlay, size.height), playPaint);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.elapsedSec != elapsedSec ||
        oldDelegate.durationSec != durationSec;
  }

  String _fmt(int sec) {
    final mm = (sec ~/ 60).toString().padLeft(2, '0');
    final ss = (sec % 60).toString().padLeft(2, '0');
    return "$mm:$ss";
  }
}
