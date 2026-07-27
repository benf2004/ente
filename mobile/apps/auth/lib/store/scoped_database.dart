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
// Handing out a handle and re-scoping run through one queue, so a read
// arriving mid-switch cannot open the outgoing file under the scope that is
// still current.
//
// A switch deliberately does NOT close the outgoing handle. The queue only
// covers handing the handle out: callers hold the Database they were given for
// the whole of their query, so closing it here throws database_closed under a
// read that started before the switch (a timer driven backup, say, which the
// sync suspension does not cover). Handles are kept per scope instead, at most
// one per profile the session visits, and closed explicitly — by closeScope()
// before a removed profile's files are deleted, and by close() on teardown.
mixin ScopedDatabase {
  Future<void> _queue = Future<void>.value();
  final Map<String, Future<Database>> _dbFutures = {};
  String _scope = "";

  String get scope => _scope;

  // The file [scope] owns. The empty scope keeps the original name, so
  // existing installs open the file they always have.
  String databaseNameFor(String scope);

  Future<Database> openDatabaseNamed(String databaseName);

  Future<void> setScope(String scope) => _serialised(() async {
    _scope = scope;
  });

  Future<void> close() => _serialised(() async {
    final dbFutures = _dbFutures.values.toList();
    _dbFutures.clear();
    for (final dbFuture in dbFutures) {
      await _closeQuietly(dbFuture);
    }
  });

  // Releases just [scope]'s file, so that it can be deleted. Nothing hands a
  // released handle out again; an acquisition for [scope] after this simply
  // reopens it.
  Future<void> closeScope(String scope) => _serialised(() async {
    final dbFuture = _dbFutures.remove(scope);
    if (dbFuture != null) {
      await _closeQuietly(dbFuture);
    }
  });

  Future<Database> get database => _serialised(() async {
    final scope = _scope;
    return _dbFutures[scope] ??= openDatabaseNamed(databaseNameFor(scope));
  });

  Future<void> _closeQuietly(Future<Database> dbFuture) async {
    try {
      await (await dbFuture).close();
    } catch (_) {
      // An open that never succeeded, or a handle already gone: either way
      // there is nothing left to release, and a profile removal must not be
      // held up by it.
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
