import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/setlist_persistence.dart';

final setlistsListProvider = FutureProvider((ref) async {
  return await SetlistPersistence.listSetlists();
});