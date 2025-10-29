import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../application/services/i_audio_device_service.dart';
import '../../domain/models/audio_device_model.dart';
import '../../domain/models/track_model.dart';

class NativeAudioDeviceService implements IAudioDeviceService {
  static const EventChannel _eventChannel = EventChannel('audio_usb/events');
  static const MethodChannel _methodChannel =
      MethodChannel('audio_usb/methods');

  final StreamController<AudioDevice?> _controller =
      StreamController<AudioDevice?>.broadcast();
  StreamSubscription? _nativeSubscription;

  NativeAudioDeviceService() {
    // Somente Android possui implementação nativa destes canais; em outras
    // plataformas (macOS, iOS, web, etc.) evitamos escutar para não quebrar.
    if (Platform.isAndroid) {
      _nativeSubscription =
          _eventChannel.receiveBroadcastStream().listen((event) async {
        if (event == 'connected') {
          final devices = await getAvailableDevices();
          _controller.add(devices.isNotEmpty ? devices.first : null);
        } else if (event == 'disconnected') {
          _controller.add(null);
        }
      }, onError: (error) {
        _controller.add(null);
      });
    } else {
      // Em plataformas sem implementação, emite null para indicar ausência de dispositivo
      scheduleMicrotask(() => _controller.add(null));
    }
  }

  @override
  Stream<AudioDevice?> get onDeviceChanged => _controller.stream;

  @override
  Future<List<AudioDevice>> getAvailableDevices() async {
    // Apenas Android possui implementação destes métodos via MethodChannel.
    if (!Platform.isAndroid) {
      return [];
    }
    try {
      final outputResult =
          await _methodChannel.invokeMethod<dynamic>('getOutputChannelDetails');
      int outputCount = 0;
      String deviceName = '';
      if (outputResult is Map) {
        deviceName = (outputResult['deviceName'] ?? '') as String;
        outputCount = (outputResult['outputChannelCount'] ?? 0) as int;
      }

      int inputCount = 0;
      try {
        final inputResult = await _methodChannel
            .invokeMethod<dynamic>('getInputChannelDetails');
        if (inputResult is Map) {
          // Preferir o mesmo dispositivo; se nome vier vazio, mantém o anterior
          final inputName = (inputResult['deviceName'] ?? '') as String;
          if (deviceName.isEmpty && inputName.isNotEmpty) {
            deviceName = inputName;
          }
          inputCount = (inputResult['inputChannelCount'] ?? 0) as int;
        }
      } catch (_) {
        // Se não implementado, mantém inputCount = 0
      }

      if (deviceName.isEmpty && outputCount == 0 && inputCount == 0) return [];
      final device = AudioDevice(
        id: deviceName.isNotEmpty ? deviceName : 'Dispositivo USB',
        name: deviceName.isNotEmpty ? deviceName : 'Dispositivo USB',
        outputChannels: outputCount,
        inputChannels: inputCount,
      );
      return [device];
    } catch (_) {
      // ignore errors and return empty list
    }
    return [];
  }

  @override
  Future<void> playPreview(String filePath, int outputChannel) async {
    if (!Platform.isAndroid) {
      // Sem suporte nativo fora do Android
      debugPrint('playPreview ignorado: plataforma não suportada');
      return;
    }
    try {
      await _methodChannel.invokeMethod('playPreview', {
        'filePath': filePath,
        'outputChannel': outputChannel,
      });
      // Log success return from native
      // ignore: avoid_print
      debugPrint('Native playPreview invoked: filePath=$filePath channel=$outputChannel');
    } catch (_) {
      // Log error for diagnostics
      debugPrint('Native playPreview error: $_');
      rethrow;
    }
  }

  @override
  Future<void> stopPreview() async {
    if (!Platform.isAndroid) {
      // Sem suporte nativo fora do Android; considerar como stopped
      debugPrint('stopPreview ignorado: plataforma não suportada');
      return;
    }
    try {
      await _methodChannel.invokeMethod('stopPreview');
      debugPrint('Native stopPreview invoked');
    } catch (_) {
      debugPrint('Native stopPreview error: $_');
    }
  }

  @override
  Future<void> setPreviewVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    if (!Platform.isAndroid) {
      debugPrint('setPreviewVolume ignorado: plataforma não suportada');
      return;
    }
    try {
      await _methodChannel.invokeMethod('setPreviewVolume', {
        'volume': v,
      });
      debugPrint('Native setPreviewVolume invoked: volume=$v');
    } catch (e) {
      debugPrint('Native setPreviewVolume error: $e');
    }
  }

  @override
  Future<void> setPreviewPan(double pan) async {
    final p = pan.clamp(-1.0, 1.0);
    if (!Platform.isAndroid) {
      debugPrint('setPreviewPan ignorado: plataforma não suportada');
      return;
    }
    try {
      await _methodChannel.invokeMethod('setPreviewPan', {
        'pan': p,
      });
      debugPrint('Native setPreviewPan invoked: pan=$p');
    } catch (e) {
      debugPrint('Native setPreviewPan error: $e');
    }
  }

  @override
  Future<void> setTrackVolume(int trackIndex, double volume) async {
    if (!Platform.isAndroid) {
      debugPrint('setTrackVolume ignorado: plataforma não suportada');
      return;
    }
    try {
      await _methodChannel.invokeMethod('setTrackVolume', {
        'trackIndex': trackIndex,
        'volume': volume.clamp(0.0, 1.0),
      });
      debugPrint('Native setTrackVolume invoked: idx=$trackIndex vol=$volume');
    } catch (e) {
      debugPrint('Native setTrackVolume error: $e');
      rethrow;
    }
  }

  @override
  Future<void> setTrackPan(int trackIndex, double pan) async {
    if (!Platform.isAndroid) {
      debugPrint('setTrackPan ignorado: plataforma não suportada');
      return;
    }
    try {
      await _methodChannel.invokeMethod('setTrackPan', {
        'trackIndex': trackIndex,
        'pan': pan.clamp(-1.0, 1.0),
      });
      debugPrint('Native setTrackPan invoked: idx=$trackIndex pan=$pan');
    } catch (e) {
      debugPrint('Native setTrackPan error: $e');
      rethrow;
    }
  }

  @override
  Future<void> playAllTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    if (!Platform.isAndroid) {
      debugPrint('playAllTracks ignorado: plataforma não suportada');
      return;
    }
    try {
      final filePaths = tracks.map((t) => t.localFilePath).toList();
      final outputChannels = tracks.map((t) => t.outputChannel).toList();
      final volumes = tracks.map((t) => t.volume.clamp(0.0, 1.0)).toList();
      final pans = tracks.map((t) => t.pan.clamp(-1.0, 1.0)).toList();
      await _methodChannel.invokeMethod('playAllPreview', {
        'filePaths': filePaths,
        'outputChannels': outputChannels,
        'volumes': volumes,
        'pans': pans,
      });
      debugPrint('Native playAllPreview invoked with ${tracks.length} tracks');
    } catch (e) {
      debugPrint('Native playAllPreview error: $e');
      rethrow;
    }
  }

  @override
  Future<void> seekPlayAll(double positionSec) async {
    if (!Platform.isAndroid) {
      debugPrint('seekPlayAll ignorado: plataforma não suportada');
      return;
    }
    final p = positionSec.isFinite && positionSec >= 0 ? positionSec : 0.0;
    try {
      await _methodChannel.invokeMethod('seekPlayAll', {
        'positionSec': p,
      });
      debugPrint('Native seekPlayAll invoked: posSec=$p');
    } catch (e) {
      debugPrint('Native seekPlayAll error: $e');
      rethrow;
    }
  }

  void dispose() {
    _nativeSubscription?.cancel();
    _controller.close();
  }
}