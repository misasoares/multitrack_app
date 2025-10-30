import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';

import '../../application/services/i_bpm_analyzer_service.dart';

class AndroidNativeBpmAnalyzerService implements IBpmAnalyzerService {
  static const MethodChannel _methodChannel = MethodChannel('audio_usb/methods');

  @override
  Future<BpmDetectionResult> detectFromFile(String filePath) async {
    // Apenas Android possui implementação nativa real.
    if (!Platform.isAndroid) {
      return _fallbackHeuristic(filePath);
    }
    try {
      final result = await _methodChannel.invokeMethod<dynamic>(
        'detectBpmFromFile',
        {
          'filePath': filePath,
        },
      );
      if (result is Map) {
        final bpmNum = result['bpm'];
        final confNum = result['confidence'];
        final bpm = bpmNum is int ? bpmNum : (bpmNum is double ? bpmNum.round() : 120);
        final conf = confNum is double ? confNum : (confNum is int ? confNum.toDouble() : 0.4);
        return BpmDetectionResult(bpm: bpm, confidence: conf.clamp(0.0, 1.0));
      }
      // Se formato inesperado, usa heurística
      return _fallbackHeuristic(filePath);
    } on PlatformException catch (_) {
      return _fallbackHeuristic(filePath);
    } catch (_) {
      return _fallbackHeuristic(filePath);
    }
  }

  BpmDetectionResult _fallbackHeuristic(String filePath) {
    final lower = filePath.toLowerCase();
    final candidates = <int>[128, 130, 126, 100, 90, 140, 110, 160, 80, 96, 105, 115, 120];
    int guess = 120;
    for (final c in candidates) {
      if (lower.contains('${c}bpm') || lower.contains('_$c') || lower.contains('-$c')) {
        guess = c;
        break;
      }
    }
    return BpmDetectionResult(bpm: guess, confidence: 0.4);
  }
}