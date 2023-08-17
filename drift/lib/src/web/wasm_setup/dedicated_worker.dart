// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:html';

import 'package:drift/wasm.dart';
import 'package:js/js_util.dart';
import 'package:sqlite3/wasm.dart';

import '../../utils/synchronized.dart';
import 'protocol.dart';
import 'shared.dart';

class DedicatedDriftWorker {
  final DedicatedWorkerGlobalScope self;
  final Lock _checkCompatibility = Lock();

  final DriftServerController _servers = DriftServerController();
  WasmCompatibility? _compatibility;

  DedicatedDriftWorker(this.self);

  void start() {
    print('dedicated worker started');
    self.onMessage.listen((event) {
      final message = WasmInitializationMessage.read(event);
      _handleMessage(message);
    });
  }

  Future<void> _handleMessage(WasmInitializationMessage message) async {
    print('dedicated worker Received message: $message');
    switch (message) {
      case RequestCompatibilityCheck(databaseName: var dbName):
        print('Requesting compatibility check for $dbName');
        bool supportsOpfs = false, supportsIndexedDb = false;

        await _checkCompatibility.synchronized(() async {
          final knownResults = _compatibility;

          if (knownResults != null) {
            supportsOpfs = knownResults.supportsOpfs;
            supportsIndexedDb = knownResults.supportsIndexedDb;
          } else {
            supportsOpfs = await checkOpfsSupport();
            supportsIndexedDb = await checkIndexedDbSupport();
            _compatibility = WasmCompatibility(supportsIndexedDb, supportsOpfs);
          }
        });

        final existingServer = _servers.servers[dbName];

        var indexedDbExists = false, opfsExists = false;
        final existingDatabases = <ExistingDatabase>[];

        if (supportsOpfs) {
          for (final database in await opfsDatabases()) {
            existingDatabases.add((WebStorageApi.opfs, database));

            if (database == dbName) {
              opfsExists = true;
            }
          }
        }

        if (existingServer != null) {
          indexedDbExists = existingServer.storage.isIndexedDbBased;
          opfsExists = existingServer.storage.isOpfsBased;
        } else if (supportsIndexedDb) {
          indexedDbExists = await checkIndexedDbExists(dbName);
        }

        final res = DedicatedWorkerCompatibilityResult(
          supportsNestedWorkers: hasProperty(globalThis, 'Worker'),
          canAccessOpfs: supportsOpfs,
          supportsIndexedDb: supportsIndexedDb,
          supportsSharedArrayBuffers:
              hasProperty(globalThis, 'SharedArrayBuffer'),
          opfsExists: opfsExists,
          indexedDbExists: indexedDbExists,
          existingDatabases: existingDatabases,
        );
        print('compatibility result: '
            '  supportsNestedWorkers: ${res.supportsNestedWorkers},'
            '  canAccessOpfs: ${res.canAccessOpfs},'
            '  supportsIndexedDb: ${res.supportsIndexedDb},'
            '  supportsSharedArrayBuffers: ${res.supportsSharedArrayBuffers},'
            '  opfsExists: ${res.opfsExists},'
            '  indexedDbExists: ${res.indexedDbExists},'
            '  existingDatabases: ${res.existingDatabases}');
        res.sendToClient(self);
      case ServeDriftDatabase():
        print('Serving drift database');
        _servers.serve(message);
      case StartFileSystemServer(sqlite3Options: final options):
        print('Starting file system server: $options');
        final worker = await VfsWorker.create(options);
        self.postMessage(true);
        await worker.start();
      case DeleteDatabase(database: (final storage, final name)):
        print('Deleting database: $storage, $name');
        try {
          switch (storage) {
            case WebStorageApi.indexedDb:
              await deleteDatabaseInIndexedDb(name);
            case WebStorageApi.opfs:
              await deleteDatabaseInOpfs(name);
          }

          // Send the request back to indicate a successful delete.
          message.sendToClient(self);
        } catch (e) {
          print('Error deleting database: $e');
          WorkerError(e.toString()).sendToClient(self);
        }

        break;
      default:
        break;
    }
  }
}
