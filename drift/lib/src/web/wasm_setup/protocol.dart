// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:html';
import 'dart:js';
import 'dart:js_interop';

import 'package:js/js_util.dart';
import 'package:sqlite3/wasm.dart';

import 'types.dart';

typedef PostMessage = void Function(Object? msg, [List<Object>? transfer]);

/// Sealed superclass for JavaScript objects exchanged between the UI tab and
/// workers spawned by drift to find a suitable database implementation.
sealed class WasmInitializationMessage {
  WasmInitializationMessage();

  factory WasmInitializationMessage.fromJs(Object jsObject) {
    final type = getProperty<String>(jsObject, 'type');
    final payload = getProperty<Object?>(jsObject, 'payload');

    switch (type) {
      case WorkerError.type:
        print('WorkerError: ${payload!}');
        break;
      case ServeDriftDatabase.type:
        print('ServeDriftDatabase.fromJsPayload ${payload!}');
        break;
      case StartFileSystemServer.type:
        print('StartFileSystemServer.fromJsPayload ${payload!}');
        break;
      case RequestCompatibilityCheck.type:
        print('RequestCompatibilityCheck.fromJsPayload ${payload!}');
        break;
      case DedicatedWorkerCompatibilityResult.type:
        print('DedicatedWorkerCompatibilityResult.fromJsPayload ${payload!}');
        break;
      case SharedWorkerCompatibilityResult.type:
        print('SharedWorkerCompatibilityResult.fromJsPayload ${payload!}');
        break;
      case DeleteDatabase.type:
        print('DeleteDatabase.fromJsPayload ${payload!}');
        break;
      default:
        throw ArgumentError('Unknown type $type');
    }

    return switch (type) {
      WorkerError.type => WorkerError.fromJsPayload(payload),
      ServeDriftDatabase.type => ServeDriftDatabase.fromJsPayload(payload),
      StartFileSystemServer.type =>
        StartFileSystemServer.fromJsPayload(payload),
      RequestCompatibilityCheck.type =>
        RequestCompatibilityCheck.fromJsPayload(payload),
      DedicatedWorkerCompatibilityResult.type =>
        DedicatedWorkerCompatibilityResult.fromJsPayload(payload),
      SharedWorkerCompatibilityResult.type =>
        SharedWorkerCompatibilityResult.fromJsPayload(payload),
      DeleteDatabase.type => DeleteDatabase.fromJsPayload(payload),
      _ => throw ArgumentError('Unknown type $type'),
    };
  }

  factory WasmInitializationMessage.read(MessageEvent event) {
    // Not using event.data because we don't want the SDK to dartify the raw JS
    // object we're passing around.
    final rawData = getProperty<Object>(event, 'data');
    print('Received message from worker: $rawData');
    return WasmInitializationMessage.fromJs(rawData);
  }

  void sendTo(PostMessage sender);

  void sendToWorker(Worker worker) {
    sendTo(worker.postMessage);
  }

  void sendToPort(MessagePort port) {
    sendTo(port.postMessage);
  }

  void sendToClient(DedicatedWorkerGlobalScope worker) {
    sendTo(worker.postMessage);
  }
}

sealed class CompatibilityResult extends WasmInitializationMessage {
  /// All existing databases.
  ///
  /// This list is only reported by the drift worker shipped with drift 2.11.
  /// When an older worker is used, only [indexedDbExists] and [opfsExists] can
  /// be used to check whether the database exists.
  final List<ExistingDatabase> existingDatabases;

  final bool indexedDbExists;
  final bool opfsExists;

  Iterable<MissingBrowserFeature> get missingFeatures;

  CompatibilityResult({
    required this.existingDatabases,
    required this.indexedDbExists,
    required this.opfsExists,
  });
}

/// A message used by the shared worker to report compatibility results.
///
/// It describes the features available from the shared worker, which the tab
/// can use to infer a desired storage implementation, or whether the shared
/// worker should be used at all.
final class SharedWorkerCompatibilityResult extends CompatibilityResult {
  static const type = 'SharedWorkerCompatibilityResult';

  final bool canSpawnDedicatedWorkers;
  final bool dedicatedWorkersCanUseOpfs;
  final bool canUseIndexedDb;

  SharedWorkerCompatibilityResult({
    required this.canSpawnDedicatedWorkers,
    required this.dedicatedWorkersCanUseOpfs,
    required this.canUseIndexedDb,
    required super.indexedDbExists,
    required super.opfsExists,
    required super.existingDatabases,
  });

  factory SharedWorkerCompatibilityResult.fromJsPayload(Object payload) {
    final asList = payload as List;
    final asBooleans = asList.cast<bool>();

    final List<ExistingDatabase> existingDatabases;
    if (asList.length > 5) {
      existingDatabases =
          EncodeLocations.readFromJs(asList[5] as List<dynamic>);
    } else {
      existingDatabases = const [];
    }

    return SharedWorkerCompatibilityResult(
      canSpawnDedicatedWorkers: asBooleans[0],
      dedicatedWorkersCanUseOpfs: asBooleans[1],
      canUseIndexedDb: asBooleans[2],
      indexedDbExists: asBooleans[3],
      opfsExists: asBooleans[4],
      existingDatabases: existingDatabases,
    );
  }

  @override
  void sendTo(PostMessage sender) {
    sender.sendTyped(type, [
      canSpawnDedicatedWorkers,
      dedicatedWorkersCanUseOpfs,
      canUseIndexedDb,
      indexedDbExists,
      opfsExists,
      existingDatabases.encodeToJs(),
    ]);
  }

  @override
  Iterable<MissingBrowserFeature> get missingFeatures sync* {
    if (!canSpawnDedicatedWorkers) {
      yield MissingBrowserFeature.dedicatedWorkersInSharedWorkers;
    } else if (!dedicatedWorkersCanUseOpfs) {
      yield MissingBrowserFeature.fileSystemAccess;
    }
  }
}

/// A message sent by a worker when an error occurred.
final class WorkerError extends WasmInitializationMessage implements Exception {
  static const type = 'Error';

  final String error;

  WorkerError(this.error);

  factory WorkerError.fromJsPayload(Object payload) {
    final pstr = payload as String;
    print('WorkerError.fromJsPayload $pstr');
    return WorkerError(pstr);
  }

  @override
  void sendTo(PostMessage sender) {
    sender.sendTyped(type, error);
  }

  @override
  String toString() {
    return 'Error in worker: $error';
  }
}

/// Instructs a dedicated or shared worker to serve a drift database connection
/// used by the main tab.
final class ServeDriftDatabase extends WasmInitializationMessage {
  static const type = 'ServeDriftDatabase';

  final Uri sqlite3WasmUri;
  final MessagePort port;
  final WasmStorageImplementation storage;
  final String databaseName;
  final MessagePort? initializationPort;

  ServeDriftDatabase({
    required this.sqlite3WasmUri,
    required this.port,
    required this.storage,
    required this.databaseName,
    required this.initializationPort,
  });

  factory ServeDriftDatabase.fromJsPayload(Object payload) {
    return ServeDriftDatabase(
      sqlite3WasmUri: Uri.parse(getProperty(payload, 'sqlite')),
      port: getProperty(payload, 'port'),
      storage: WasmStorageImplementation.values
          .byName(getProperty(payload, 'storage')),
      databaseName: getProperty(payload, 'database'),
      initializationPort: getProperty(payload, 'initPort'),
    );
  }

  @override
  void sendTo(PostMessage sender) {
    print('ServeDriftDatabase.sendTo starting'
        '  sqlite3WasmUri: $sqlite3WasmUri'
        '  port: $port'
        '  storage: $storage'
        '  databaseName: $databaseName'
        '  initializationPort: $initializationPort');
    final object = newObject<Object>();
    setProperty(object, 'sqlite', sqlite3WasmUri.toString());
    setProperty(object, 'port', port);
    setProperty(object, 'storage', storage.name);
    setProperty(object, 'database', databaseName);
    final initPort = initializationPort;
    setProperty(object, 'initPort', initPort);

    sender.sendTyped(type, object, [
      port,
      if (initPort != null) initPort,
    ]);
  }
}

final class RequestCompatibilityCheck extends WasmInitializationMessage {
  static const type = 'RequestCompatibilityCheck';

  /// The database name to check when reporting whether it exists already.
  ///
  /// Older versions of the drif worker only support checking a single database
  /// name. On newer workers, this field is ignored.
  final String databaseName;

  RequestCompatibilityCheck(this.databaseName);

  factory RequestCompatibilityCheck.fromJsPayload(Object? payload) {
    return RequestCompatibilityCheck(payload as String);
  }

  @override
  void sendTo(PostMessage sender) {
    sender.sendTyped(type, databaseName);
  }
}

final class DedicatedWorkerCompatibilityResult extends CompatibilityResult {
  static const type = 'DedicatedWorkerCompatibilityResult';

  final bool supportsNestedWorkers;
  final bool canAccessOpfs;
  final bool supportsSharedArrayBuffers;
  final bool supportsIndexedDb;

  DedicatedWorkerCompatibilityResult({
    required this.supportsNestedWorkers,
    required this.canAccessOpfs,
    required this.supportsSharedArrayBuffers,
    required this.supportsIndexedDb,
    required super.indexedDbExists,
    required super.opfsExists,
    required super.existingDatabases,
  });

  factory DedicatedWorkerCompatibilityResult.fromJsPayload(Object payload) {
    final existingDatabases = <ExistingDatabase>[];

    if (hasProperty(payload, 'existing')) {
      existingDatabases
          .addAll(EncodeLocations.readFromJs(getProperty(payload, 'existing')));
    }

    print('DedicatedWorkerCompatibilityResult: '
        '  supportsNestedWorkers: ${getProperty(payload, 'supportsNestedWorkers')},'
        '  canAccessOpfs: ${getProperty(payload, 'canAccessOpfs')},'
        '  supportsSharedArrayBuffers: ${getProperty(payload, 'supportsSharedArrayBuffers')},'
        '  supportsIndexedDb: ${getProperty(payload, 'supportsIndexedDb')},'
        '  indexedDbExists: ${getProperty(payload, 'indexedDbExists')},'
        '  opfsExists: ${getProperty(payload, 'opfsExists')},'
        '  existingDatabase: $existingDatabases');
    return DedicatedWorkerCompatibilityResult(
      supportsNestedWorkers: getProperty(payload, 'supportsNestedWorkers'),
      canAccessOpfs: getProperty(payload, 'canAccessOpfs'),
      supportsSharedArrayBuffers:
          getProperty(payload, 'supportsSharedArrayBuffers'),
      supportsIndexedDb: getProperty(payload, 'supportsIndexedDb'),
      indexedDbExists: getProperty(payload, 'indexedDbExists'),
      opfsExists: getProperty(payload, 'opfsExists'),
      existingDatabases: existingDatabases,
    );
  }

  @override
  void sendTo(PostMessage sender) {
    final object = newObject<Object>();

    setProperty(object, 'supportsNestedWorkers', supportsNestedWorkers);
    setProperty(object, 'canAccessOpfs', canAccessOpfs);
    setProperty(object, 'supportsIndexedDb', supportsIndexedDb);
    setProperty(
        object, 'supportsSharedArrayBuffers', supportsSharedArrayBuffers);
    setProperty(object, 'indexedDbExists', indexedDbExists);
    setProperty(object, 'opfsExists', opfsExists);
    setProperty(object, 'existing', existingDatabases.encodeToJs());

    sender.sendTyped(type, object);
  }

  @override
  Iterable<MissingBrowserFeature> get missingFeatures sync* {
    if (!canAccessOpfs) {
      yield MissingBrowserFeature.fileSystemAccess;
    }
    if (!supportsSharedArrayBuffers) {
      yield MissingBrowserFeature.sharedArrayBuffers;
    }
    if (!supportsIndexedDb) {
      yield MissingBrowserFeature.indexedDb;
    }
  }
}

final class StartFileSystemServer extends WasmInitializationMessage {
  static const type = 'StartFileSystemServer';

  final WorkerOptions sqlite3Options;

  StartFileSystemServer(this.sqlite3Options);

  factory StartFileSystemServer.fromJsPayload(Object payload) {
    return StartFileSystemServer(payload as WorkerOptions);
  }

  @override
  void sendTo(PostMessage sender) {
    sender.sendTyped(type, sqlite3Options);
  }
}

final class DeleteDatabase extends WasmInitializationMessage {
  static const type = 'DeleteDatabase';

  final ExistingDatabase database;

  DeleteDatabase(this.database);

  factory DeleteDatabase.fromJsPayload(Object payload) {
    final asList = payload as List<Object?>;
    return DeleteDatabase((
      WebStorageApi.byName[asList[0] as String]!,
      asList[1] as String,
    ));
  }

  @override
  void sendTo(PostMessage sender) {
    sender.sendTyped(type, [database.$1.name, database.$2]);
  }
}

extension EncodeLocations on List<ExistingDatabase> {
  static List<ExistingDatabase> readFromJs(List<Object?> object) {
    final existing = <ExistingDatabase>[];

    for (final entry in object) {
      existing.add((
        WebStorageApi.byName[getProperty(entry as Object, 'l')]!,
        getProperty(entry, 'n'),
      ));
    }

    return existing;
  }

  Object encodeToJs() {
    final existing = JsArray<Object>();
    for (final entry in this) {
      final object = newObject<Object>();
      setProperty(object, 'l', entry.$1.name);
      setProperty(object, 'n', entry.$2);

      existing.add(object);
    }

    return existing;
  }
}

extension on PostMessage {
  void sendTyped(String type, Object? payload, [List<Object>? transfer]) {
    final object = newObject<Object>();
    setProperty(object, 'type', type);
    setProperty(object, 'payload', payload);

    call(object, transfer);
  }
}
