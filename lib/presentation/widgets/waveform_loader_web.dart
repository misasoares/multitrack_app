class WaveformData {
  final List<double> peaks;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataBytes;
  final double durationSec;
  WaveformData({
    required this.peaks,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
    required this.durationSec,
  });
}

Future<WaveformData> loadWaveform(String path, {int targetPoints = 1000}) async {
  // Web stub: file IO indisponível. Retorna placeholder de linha reta.
  return WaveformData(
    peaks: List<double>.filled(targetPoints, 0.2),
    sampleRate: 44100,
    channels: 2,
    bitsPerSample: 16,
    dataBytes: 0,
    durationSec: 0,
  );
}