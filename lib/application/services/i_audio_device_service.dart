import 'dart:async';
import '../../domain/models/audio_device_model.dart';
import '../../domain/models/track_model.dart';

abstract class IAudioDeviceService {
  Stream<AudioDevice?> get onDeviceChanged;
  Future<List<AudioDevice>> getAvailableDevices();
  Future<void> playPreview(String filePath, int outputChannel);
  Future<void> stopPreview();
  Future<void> setPreviewVolume(double volume);
  Future<void> setPreviewPan(double pan);
  Future<void> setTrackVolume(int trackIndex, double volume);
  Future<void> setTrackPan(int trackIndex, double pan);
  Future<void> playAllTracks(List<Track> tracks);
  Future<void> seekPlayAll(double positionSec);
  // Optional optimizations (no-op on unsupported platforms)
  Future<void> prepareTracks(List<Track> tracks);
  Future<void> setOutputQuality({
    int? sampleRateHz,
    int? bitDepth,
    int? bufferSizeFrames,
    bool? lowLatency,
    bool? disableResample,
    bool? enableDither,
  });
  // Optional: query file metadata (sample rate) if supported
  Future<int?> getFileSampleRateHz(String filePath);
  // Optional: get recommended buffer size in frames for current device
  Future<int?> getRecommendedBufferSizeFrames();
}