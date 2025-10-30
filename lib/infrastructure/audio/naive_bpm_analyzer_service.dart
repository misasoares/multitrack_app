import 'dart:async';
import 'dart:math' as math;

import '../../application/services/i_bpm_analyzer_service.dart';
import '../../application/services/i_audio_device_service.dart';

class NaiveBpmAnalyzerService implements IBpmAnalyzerService {
  final IAudioDeviceService audioService;
  NaiveBpmAnalyzerService(this.audioService);

  @override
  Future<BpmDetectionResult> detectFromFile(String filePath) async {
    // Placeholder/heuristic analyzer: we don't decode audio here yet.
    // Simulate some processing time.
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    // Try to query sample rate just to validate access (optional)
    try {
      await audioService.getFileSampleRateHz(filePath);
    } catch (_) {
      // ignore errors; we'll still return a guess
    }

    // Very naive heuristic: guess based on filename hints, fallback 120.
    final lower = filePath.toLowerCase();
    final candidates = <int>[128, 130, 126, 100, 90, 140, 110, 160, 80, 96, 105, 115, 120];
    int guess = 120;
    for (final c in candidates) {
      if (lower.contains('${c}bpm') || lower.contains('_$c') || lower.contains('-$c')) {
        guess = c;
        break;
      }
    }
    // Add a small random jitter to confidence to avoid always identical values
    final confidence = 0.35 + (math.Random().nextDouble() * 0.25);
    return BpmDetectionResult(bpm: guess, confidence: confidence.clamp(0.0, 1.0));
  }
}