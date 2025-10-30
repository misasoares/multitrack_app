import 'dart:async';

class BpmDetectionResult {
  final int bpm;
  final double confidence; // 0..1
  BpmDetectionResult({required this.bpm, required this.confidence});
}

abstract class IBpmAnalyzerService {
  Future<BpmDetectionResult> detectFromFile(String filePath);
}