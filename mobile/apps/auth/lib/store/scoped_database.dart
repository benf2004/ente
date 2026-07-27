import 'dart:async';
import 'dart:io';

import 'package:ente_auth/utils/directory_utils.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Where [databaseName] lives on this platform. Shared so that opening a
// database and erasing a removed profile's files cannot disagree about the
// location: a path resolved in only one of the two places would leave the
// other silently operating on nothing.
Future<String> databasePathForName(String databaseName) async {
  if (Platform.isWindows || Platform.isLinux) {
    return DirectoryUtils.getDatabasePath(databaseName);
  }
  final Directory directory = Platform.isMacOS
      ? await getApplicationSupportDirectory()
      : await getApplicationDocumentsDirectory();
  return join(directory.path, databaseName);
}

// The per-profile scope plumbing shared by the code databases.
//
// Opening, closing and re-scoping all run through one queue. Without that
// serialisation a read arriving while setScope() is closing the outgoing file
// reopens it under the scope that is still current, and the resulting handle
// outlives the switch: the app believes it moved to the new profile while
// every query keeps hitting the previous profile's codes.
mixin ScopedDatabase {
  Future<void> _queue = Future<void>.value();
  Future<Database>? _dbFuture;
  String _scope = "";

  String get scope => _scope;

  // The file [scope] owns. The empty scope keeps the original name, so
  // existing installs open the file they always have.
  String databaseNameFor(String scope);

  Future<Database> openDatabaseNamed(String databaseName);

  Future<void> setScope(String scope) => _serialised(() async {
    if (_scope == scope) return;
    await _close();
    _scope = scope;
  });

  Future<void> close() => _serialised(_close);

  Future<Database> get database => _serialised(
    () async => _dbFuture ??= openDatabaseNamed(databaseNameFor(_scope)),
  );

  Future<void> _close() async {
    final dbFuture = _dbFuture;
    _dbFuture = null;
    if (dbFuture != null) {
      await (await dbFuture).close();
    }
  }

  Future<T> _serialised<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _queue;
    // Assigned before awaiting, so a caller arriving mid-switch queues behind
    // it rather than racing it.
    _queue = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
