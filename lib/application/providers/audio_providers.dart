import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'device_provider.dart';
import '../services/i_bpm_analyzer_service.dart';
import '../../infrastructure/audio/naive_bpm_analyzer_service.dart';
import 'dart:io' show Platform;
import '../../infrastructure/audio/android_bpm_analyzer_service.dart';

// Controls which track is currently previewing (or null if none)
final previewingTrackIdProvider =
    StateProvider.autoDispose<int?>((ref) => null);

// Playhead (mix) in seconds, published by MixerScreen; widgets can watch to sync UI.
final playheadSecProvider = StateProvider<double>((ref) => 0.0);

// UI: Snap aos beats (habilita ajuste de seek/criação quando metrônomo estiver ativo)
final snapToBeatsProvider = StateProvider<bool>((ref) => false);

// Controls which track is set as metronome (or null if none)
final metronomeTrackIdProvider = StateProvider<int?>((ref) => null);

// Per-song BPM used for snapping. Default 120 BPM. Not persisted yet.
final songBpmProvider = StateProvider.family<int, int>((ref, songId) => 120);

// Mixer busy state: disables interactions and shows an overlay during long operations
final mixerBusyProvider = StateProvider<bool>((ref) => false);

// BPM analyzer service: detects BPM from an audio file of the metronome track
final bpmAnalyzerServiceProvider = Provider<IBpmAnalyzerService>((ref) {
  final audioSvc = ref.watch(audioDeviceServiceProvider);
  if (Platform.isAndroid) {
    return AndroidNativeBpmAnalyzerService();
  }
  return NaiveBpmAnalyzerService(audioSvc);
});
