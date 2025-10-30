import 'package:isar/isar.dart';

part 'track_model.g.dart';

@collection
class Track {
  Id id = Isar.autoIncrement;
  late String name; // Nome editável (ex: "Bateria")
  late String localFilePath; // Caminho do arquivo dentro do app

  double volume = 1.0;
  double pan = 0.0;
  int outputChannel = 0; // O canal de roteamento
  int inputChannel = 0; // Canal de entrada (para gravação/roteamento)
  bool isMetronome = false; // Define se esta faixa é o metrônomo

  Track copyWith({
    String? name,
    String? localFilePath,
    double? volume,
    double? pan,
    int? outputChannel,
    int? inputChannel,
    bool? isMetronome,
  }) {
    final t = Track()
      ..id = id
      ..name = name ?? this.name
      ..localFilePath = localFilePath ?? this.localFilePath
      ..volume = volume ?? this.volume
      ..pan = pan ?? this.pan
      ..outputChannel = outputChannel ?? this.outputChannel
      ..inputChannel = inputChannel ?? this.inputChannel
      ..isMetronome = isMetronome ?? this.isMetronome;
    return t;
  }
}
