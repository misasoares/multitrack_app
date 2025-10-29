import 'package:isar/isar.dart';
import 'track_model.dart';

part 'song_model.g.dart';

@collection
class Song {
  Id id = Isar.autoIncrement;
  late String name;
  final tracks = IsarLinks<Track>();
}