import 'dart:io';
import 'dart:math' as math;

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
  final file = File(path);
  if (!await file.exists()) {
    return WaveformData(
      peaks: const [],
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 16,
      dataBytes: 0,
      durationSec: 0,
    );
  }

  final raf = file.openSync(mode: FileMode.read);
  try {
    final header = raf.readSync(12);
    if (String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      return WaveformData(
        peaks: const [],
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        dataBytes: 0,
        durationSec: 0,
      );
    }
    int sampleRate = 44100;
    int channels = 2;
    int bitsPerSample = 16;
    int fmtAudioFormat = 1;
    int dataOffset = -1;
    int dataSize = 0;
    while (true) {
      final chunkHeader = raf.readSync(8);
      if (chunkHeader.length < 8) break;
      final id = String.fromCharCodes(chunkHeader.sublist(0, 4));
      final size = _bytesToIntLE(chunkHeader.sublist(4, 8));
      if (id == 'fmt ') {
        final fmt = raf.readSync(size);
        fmtAudioFormat = _bytesToIntLE(fmt.sublist(0, 2));
        channels = _bytesToIntLE(fmt.sublist(2, 4));
        sampleRate = _bytesToIntLE(fmt.sublist(4, 8));
        bitsPerSample = _bytesToIntLE(fmt.sublist(14, 16));
      } else if (id == 'data') {
        dataOffset = raf.positionSync();
        dataSize = size;
        raf.setPositionSync(raf.positionSync() + size);
      } else {
        raf.setPositionSync(raf.positionSync() + size);
      }
      if (size.isOdd) raf.setPositionSync(raf.positionSync() + 1);
    }
    if (fmtAudioFormat != 1 || dataOffset < 0 || dataSize <= 0) {
      return WaveformData(
        peaks: const [],
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        dataBytes: 0,
        durationSec: 0,
      );
    }
    final durationSec = dataSize / (sampleRate * channels * (bitsPerSample / 8));
    final frameBytes = (bitsPerSample / 8).round();
    final bytesPerFrame = frameBytes * channels;
    final framesTotal = (dataSize / bytesPerFrame).floor();
    final framesPerBucket = math.max(1, (framesTotal / targetPoints).floor());
    final bucketBytes = framesPerBucket * bytesPerFrame;
    final peaks = <double>[];
    raf.setPositionSync(dataOffset);
    final buf = List<int>.filled(bucketBytes, 0);
    for (int i = 0; i < targetPoints; i++) {
      final read = raf.readIntoSync(buf, 0, bucketBytes);
      if (read <= 0) break;
      double peak = 0.0;
      if (bitsPerSample == 16) {
        for (int j = 0; j + 1 < read; j += bytesPerFrame) {
          int s1 = _int16LE(buf, j);
          double amp = (s1.abs()) / 32768.0;
          if (channels > 1 && j + 2 < read) {
            int s2 = _int16LE(buf, j + 2);
            amp = ((s1.abs() + s2.abs()) / 2.0) / 32768.0;
          }
          if (amp > peak) peak = amp;
        }
      } else {
        double sum = 0;
        for (int b = 0; b < read; b += bytesPerFrame) { sum += buf[b].abs(); }
        peak = (sum / read) / 255.0;
      }
      peaks.add(peak);
    }
    return WaveformData(
      peaks: peaks,
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
      dataBytes: dataSize,
      durationSec: durationSec,
    );
  } finally {
    raf.closeSync();
  }
}

int _bytesToIntLE(List<int> bytes) {
  int v = 0;
  for (int i = 0; i < bytes.length; i++) { v |= (bytes[i] & 0xFF) << (8 * i); }
  return v;
}

int _int16LE(List<int> buf, int offset) {
  int lo = buf[offset] & 0xFF;
  int hi = buf[offset + 1] & 0xFF;
  int v = (hi << 8) | lo;
  if (v & 0x8000 != 0) v = v - 0x10000;
  return v;
}