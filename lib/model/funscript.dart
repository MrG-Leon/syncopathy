// A wrapper around the FunscriptJson class
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/funscript_algo.dart';
import 'package:syncopathy/model/json/funscript_json.dart';
import 'package:syncopathy/model/json/funscript_metadata.dart';

class Funscript {
  final FunscriptJson json;

  late final List<FunscriptAction> _deduplicatedActions;
  UnmodifiableListView<FunscriptAction> get originalActions =>
      UnmodifiableListView(_deduplicatedActions);
  FunscriptMetadata? get metadata => json.metadata;

  final Signal<List<FunscriptAction>> processedActions = signal([]);

  late final ReadonlySignal<double> averageSpeed = computed(
    () => FunscriptAlgorithms.averageSpeed(processedActions.value),
  );
  late final ReadonlySignal<double> averageMin = computed(
    () => FunscriptAlgorithms.averageMin(processedActions.value),
  );
  late final ReadonlySignal<double> averageMax = computed(
    () => FunscriptAlgorithms.averageMax(processedActions.value),
  );

  late final bool likelyScriptToken;

  final String filePath;
  String get fileName => p.basename(filePath);

  Funscript({required this.json, required this.filePath}) {
    likelyScriptToken = isScriptToken(json.actions);
    // remove duplicate timestamps
    final uniqueActions = <FunscriptAction>[];
    final seenTimestamps = <int>{};
    for (final action in json.actions) {
      if (seenTimestamps.add(action.at)) {
        uniqueActions.add(action);
      }
    }
    _deduplicatedActions = uniqueActions;
  }

  // This determines if something is likely a script token
  // If this is true it is highly unlikely that it isn't
  // False positives are also unlikely
  static bool isScriptToken(List<FunscriptAction> actions) {
    // 'magic' number for script token
    const magic = 136740671;
    // Script tokens can not be empty or have more than 100 actions.
    if (actions.isEmpty || actions.length > 100) {
      return false;
    }
    // Check if the script contains the token signal marker.
    for (final a in actions) {
      if (a.pos == 0 && a.at == magic % actions.length) {
        return true;
      }
    }
    return false;
  }

  static int getActionBefore(int timeMs, List<FunscriptAction> actions) {
    final index = lowerBound(actions, FunscriptAction(at: timeMs, pos: 0));
    return index == actions.length ? index - 1 : index;
  }

  static Funscript fromJson(Map<String, dynamic> funscriptMap, String path) {
    final json = FunscriptJson.fromJson(funscriptMap);
    return Funscript(json: json, filePath: path);
  }

  /// Scripts above this size are decoded off the UI isolate. Below it, isolate
  /// startup costs more than the parse itself.
  static const int _isolateParseThresholdBytes = 200000;

  static FunscriptJson _parseJsonOffUiThread(String jsonString) {
    return FunscriptJson.fromJson(
      jsonDecode(jsonString) as Map<String, dynamic>,
    );
  }

  /// Decodes a funscript payload without blocking the UI isolate when the
  /// script is large. Switching videos can otherwise stall a frame (or longer)
  /// while a multi-megabyte JSON document is parsed and turned into actions.
  static Future<Funscript?> fromJsonString(
    String jsonString,
    String path,
  ) async {
    final json = jsonString.length >= _isolateParseThresholdBytes
        ? await compute(_parseJsonOffUiThread, jsonString)
        : _parseJsonOffUiThread(jsonString);
    return Funscript(json: json, filePath: path);
  }

  /// Loads already in flight, keyed by path.
  ///
  /// Switching videos can ask for the same script twice: the media effect runs
  /// once when the track changes and again when mpv reports the new duration,
  /// and the first attempt is dropped as stale. Sharing the pending load keeps
  /// a multi-megabyte script from being read and parsed twice for one switch.
  static final Map<String, Future<Funscript?>> _loadsInFlight = {};

  static Future<Funscript?> fromFile(String path) {
    return _loadsInFlight[path] ??= _readFile(path).whenComplete(() {
      _loadsInFlight.remove(path);
    });
  }

  static Future<Funscript?> _readFile(String path) async {
    final jsonString = await File(path).readAsString();
    return fromJsonString(jsonString, path);
  }
}
