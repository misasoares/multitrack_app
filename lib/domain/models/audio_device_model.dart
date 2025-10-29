class AudioDevice {
  final String id;
  final String name;
  final int outputChannels;
  final int inputChannels;

  const AudioDevice({
    required this.id,
    required this.name,
    required this.outputChannels,
    required this.inputChannels,
  });
}
