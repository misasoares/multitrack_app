import 'package:flutter_riverpod/flutter_riverpod.dart';

// Controls which track is currently previewing (or null if none)
final previewingTrackIdProvider =
    StateProvider.autoDispose<int?>((ref) => null);

// Playhead (mix) in seconds, published by MixerScreen; widgets can watch to sync UI.
final playheadSecProvider = StateProvider<double>((ref) => 0.0);
