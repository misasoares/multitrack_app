import 'package:isar/isar.dart';

part 'endpoint_model.g.dart';

@collection
class Endpoint {
  Id id = Isar.autoIncrement;

  // Música à qual o endpoint pertence
  @Index(
    composite: [CompositeIndex('timeMs')],
    unique: true,
  )
  late int songId;

  // Momento no áudio em milissegundos (precisão máxima)
  late int timeMs;

  // Nome exibido (ex.: "Endpoint 1")
  late String label;

  // Cor em formato #RRGGBB (normalizado em maiúsculas)
  late String colorHex;

  // Data de criação (para auditoria/ordenar por criação, se necessário)
  late DateTime createdAt;
}