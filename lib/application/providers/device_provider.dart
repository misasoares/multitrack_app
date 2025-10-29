import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/audio/native_audio_device_service.dart';
import '../services/i_audio_device_service.dart';
import '../../domain/models/audio_device_model.dart';

final audioDeviceServiceProvider = Provider<IAudioDeviceService>((ref) {
  final service = NativeAudioDeviceService();
  ref.onDispose(() {
    if (service is NativeAudioDeviceService) {
      service.dispose();
    }
  });
  return service;
});

final currentDeviceProvider = StreamProvider<AudioDevice?>((ref) {
  final service = ref.watch(audioDeviceServiceProvider);
  return service.onDeviceChanged;
});