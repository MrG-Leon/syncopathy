import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/generated/constants.pb.dart';
import 'package:syncopathy/generated/handy_rpc.pb.dart';
import 'package:syncopathy/generated/messages.pb.dart';
import 'package:syncopathy/helper/debouncer.dart';
import 'package:syncopathy/helper/effect_dispose_mixin.dart';
import 'package:syncopathy/logging.dart';
import 'package:syncopathy/model/json/funscript_json.dart';
import 'package:syncopathy/player/bluetooth_connector.dart';
import 'package:syncopathy/player/handy_native_hsp_mixin.dart';
import 'package:syncopathy/player/hsp_clock_sync.dart';
import 'package:universal_ble/universal_ble.dart';

// Takes care of serializationg and deserialization on two separate isolates
class ProtobufWorker {
  late Isolate _isolateSerialize;
  late Isolate _isolateDeserialize;

  SendPort? _sendSerializePort;
  SendPort? _sendDeserializePort;

  final _resultSerializeController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get serializedStream => _resultSerializeController.stream;

  final _resultDeserializeController = StreamController<RpcMessage>.broadcast();
  Stream<RpcMessage> get deserializeStream =>
      _resultDeserializeController.stream;

  Future<void> spawn() async {
    // Serialization isolate
    if (!kIsWeb) {
      final receiveSerializePort = ReceivePort();
      _isolateSerialize = await Isolate.spawn(
        _isolateSerializeEntry,
        receiveSerializePort.sendPort,
      );

      Completer<SendPort> serializeCompleter = Completer();
      receiveSerializePort.listen((message) {
        if (message is SendPort) {
          serializeCompleter.complete(message);
        } else if (message is Uint8List) {
          _resultSerializeController.add(message);
        }
      });
      _sendSerializePort = await serializeCompleter.future;
    }

    // Deserialization isolate
    if (!kIsWeb) {
      final receiveDeserializePort = ReceivePort();
      _isolateDeserialize = await Isolate.spawn(
        _isolateDeserializeEntry,
        receiveDeserializePort.sendPort,
      );

      Completer<SendPort> deserializeCompleter = Completer();
      receiveDeserializePort.listen((message) {
        if (message is SendPort) {
          deserializeCompleter.complete(message);
        } else if (message is RpcMessage) {
          _resultDeserializeController.add(message);
        }
      });
      _sendDeserializePort = await deserializeCompleter.future;
    }
  }

  Future<void> dispose() async {
    if (!kIsWeb) {
      _isolateDeserialize.kill();
      _isolateSerialize.kill();
    }
  }

  void sendToSerialize(RpcMessage message) {
    if (!kIsWeb) {
      _sendSerializePort?.send(message);
    } else {
      final Uint8List buffer = message.writeToBuffer();
      _resultSerializeController.add(buffer);
    }
  }

  void sendToDeserialize(Uint8List message) {
    if (!kIsWeb) {
      _sendDeserializePort?.send(message);
    } else {
      final msg = RpcMessage.fromBuffer(message);
      _resultDeserializeController.add(msg);
    }
  }

  // This runs in the separate thread
  static void _isolateSerializeEntry(SendPort mainSendPort) {
    final childReceivePort = ReceivePort();
    mainSendPort.send(childReceivePort.sendPort);

    childReceivePort.listen((message) {
      final Uint8List buffer = message.writeToBuffer();
      mainSendPort.send(buffer);
    });
  }

  // This runs in the separate thread
  static void _isolateDeserializeEntry(SendPort mainSendPort) {
    final childReceivePort = ReceivePort();
    mainSendPort.send(childReceivePort.sendPort);

    childReceivePort.listen((message) {
      final msg = RpcMessage.fromBuffer(message);
      mainSendPort.send(msg);
    });
  }
}

/// An in-flight request awaiting its response, tracked so late/timed-out
/// completers can be reaped.
class _PendingRequest {
  final int id;
  final DateTime sentAt;
  final Completer<Response> completer;
  _PendingRequest(this.id, this.sentAt, this.completer);
}

class HandyBle with EffectDispose implements IHspCommands {
  final BtDevice _device;
  final List<_PendingRequest> _messageCompleters = [];

  // Handy BLE GATT identifiers, passed to the generic BluetoothConnector.
  static const serviceUuid = "77834d26-40f7-11ee-be56-0242ac120002";
  static const txUuid = "77835032-40f7-11ee-be56-0242ac120002";
  static const rxUuid = "77835410-40f7-11ee-be56-0242ac120002";

  // Max signed 32-bit int, reused as the request id meaning "no response
  // expected" and as the ceiling for random stream ids.
  static const int maxInt32 = 2147483647;

  int _messageIdCounter = 1;
  int get messageId => _messageIdCounter++;
  static const noCompletionId = maxInt32;

  ReadonlySignal<HspState?> get hspState => _hspState;
  final Signal<HspState?> _hspState = signal(null);

  ReadonlySignal<BatteryState?> get batteryState => _batteryState;
  final Signal<BatteryState?> _batteryState = signal(null);
  Timer? _batteryPolling;

  late final ReadonlySignal<bool> isConnected;
  final Signal<bool> _isConnected = signal(true);
  // BLE stacks can emit brief false disconnects. Delay false updates to
  // prevent UI flapping while keeping true updates immediate.
  static const Duration _disconnectDebounce = Duration(milliseconds: 1200);
  static const Duration _manualDisconnectAckTimeout = Duration(seconds: 3);
  Timer? _disconnectDebounceTimer;
  bool _waitingForManualDisconnectAck = false;
  Completer<void>? _manualDisconnectAckCompleter;
  // Set once the device stream has reported a disconnect (routed into the
  // debounce path). After this the status callback will never fire again, so
  // dispose() can complete its disconnect ack locally instead of waiting out
  // the timeout.
  bool _disconnectEventSeen = false;

  final Signal<int> _strokeRangeMin;
  final Signal<int> _strokeRangeMax;

  // Increments each time the clock sync runs (initial + recalibrations) so
  // observers can react to "the device clock was just re-synced".
  final Signal<int> calibrationCount = signal(0);

  // Called when threshold is reached or starving
  Function(bool)? hspThresholdReached; // bool = starving
  // Called when paused on starving notification is received
  Function()? hspPausedOnStarving;

  Function()? hspLooped;

  late final StreamSubscription _bufferReceivedSubscription;
  late final StreamSubscription _deserializeSubscription;
  late final StreamSubscription _serializeSubscription;
  late final StreamSubscription _connectionSubscription;
  final ProtobufWorker _worker = ProtobufWorker();

  final _applyStrokeRangeDebouncer = Debouncer(milliseconds: 500);
  int estimatedAverageOffset = 0;
  bool _isClockSyncing = false;

  HandyBle(this._device, this._strokeRangeMin, this._strokeRangeMax) {
    isConnected = _isConnected;
    _connectionSubscription = _device.device.connectionStream.listen(
      (connected) {
        // BLE stacks can emit brief false disconnects. Delay false updates to
        // prevent UI flapping while keeping true updates immediate.
        if (connected) {
          _disconnectDebounceTimer?.cancel();
          _disconnectDebounceTimer = null;
          _isConnected.value = true;
        } else {
          if (_waitingForManualDisconnectAck) {
            _disconnectDebounceTimer?.cancel();
            _disconnectDebounceTimer = null;
            _isConnected.value = false;
            _manualDisconnectAckCompleter?.complete();
            return;
          }
          _disconnectEventSeen = true;
          _disconnectDebounceTimer?.cancel();
          _disconnectDebounceTimer = Timer(_disconnectDebounce, () {
            _disconnectDebounceTimer = null;
            _isConnected.value = false;
          });
        }
      },
    );
    _bufferReceivedSubscription = _device.rx.onValueReceived.listen(
      _bufferReceived,
    );
    _device.rx.notifications.subscribe();
    _deserializeSubscription = _worker.deserializeStream.listen(
      _rpcMessageReceived,
    );
    _serializeSubscription = _worker.serializedStream.listen(_sendBuffer);

    effectAdd([
      effect(() {
        final min = _strokeRangeMin.value;
        final max = _strokeRangeMax.value;
        _applyStrokeRangeDebouncer.run(() {
          sliderStrokeSet(min, max);
        });
      }),
    ]);
  }

  // We are the server + estimated BT latency
  int serverTime() =>
      DateTime.now().millisecondsSinceEpoch + estimatedAverageOffset;

  Future<void> init() async {
    await _worker.spawn();
    final range = await sliderStrokeGet();
    if (range != null) {
      _strokeRangeMin.value = range.$1;
      _strokeRangeMax.value = range.$2;
    }

    // Capabilities
    final caps = await getCapabilities();
    if (caps != null) {
      if (caps.battery) {
        final battery = await getBatteryState();
        _batteryState.value = battery;
        _batteryPolling = Timer.periodic(Duration(seconds: 3), (_) async {
          try {
            final battery = await getBatteryState();
            _batteryState.value = battery;
          } catch (_) {
            _batteryPolling?.cancel();
          }
        });
      } else {
        _batteryPolling?.cancel();
        _batteryState.value = null;
      }
    }

    // Sync time (initial).
    await _syncClockTime();
  }

  /// Runs the clock offset sampling loop and pushes the result to the device.
  /// Increments [calibrationCount] on success so observers can react.
  Future<void> _syncClockTime({int syncTries = 10}) async {
    final sync = await aggregateClockSync(
      tries: syncTries,
      delay: const Duration(milliseconds: 100),
      sample: () async {
        final start = DateTime.now().millisecondsSinceEpoch;
        await getClockOffset();
        final server = DateTime.now().millisecondsSinceEpoch;
        final end = server;
        final rtd = end - start;
        return (rtd: rtd, offset: (server + (rtd / 2.0)) - end);
      },
    );
    estimatedAverageOffset = sync.averageOffset;
    final averageRtd = sync.averageRtd;
    Logger.debug(
      "Estimated average offset: $estimatedAverageOffset RTD: $averageRtd",
    );
    final offset = await getClockOffset();
    final clockOffset = serverTime() - offset!.time;
    await setClockOffset(clockOffset, rtd: averageRtd);
    calibrationCount.value += 1;
  }

  /// Re-run the clock synchronization. Intended to be called in stable device
  /// states (e.g. when entering Home Mode, or after switching videos) to
  /// minimize drift. Guarded by [_isClockSyncing] so overlapping calls are
  /// dropped rather than queued.
  Future<void> calibrateClock({int syncTries = 5}) async {
    if (_isClockSyncing) return;
    _isClockSyncing = true;
    try {
      await _syncClockTime(syncTries: syncTries);
    } finally {
      _isClockSyncing = false;
    }
  }

  static Future<HandyBle?> startScanning(
    Signal<int> strokeMin,
    Signal<int> strokeMax,
  ) async {
    final device = await BluetoothConnector().scanForDevice(
      serviceUuid,
      txUuid,
      rxUuid,
    );
    return device == null ? null : HandyBle(device, strokeMin, strokeMax);
  }

  void _bufferReceived(Uint8List buffer) {
    _worker.sendToDeserialize(buffer);
  }

  void _sendBuffer(Uint8List bufferMsg) async {
    try {
      assert(bufferMsg.length <= 512);
      await _device.tx.write(bufferMsg, withResponse: false);
    } catch (_) {
      await dispose();
    }
  }

  void _rpcMessageReceived(RpcMessage message) {
    if (message.type == MessageType.MESSAGE_TYPE_RESPONSE) {
      Response response = message.response;
      if (response.id != noCompletionId) {
        final pending = _messageCompleters.firstWhereOrNull(
          (c) => c.id == response.id,
        );
        if (pending != null) {
          _messageCompleters.remove(pending);
          pending.completer.complete(response);
        }
        // remove potentially timed out completers
        _messageCompleters.removeWhere(
          (c) => (DateTime.now().difference(c.sentAt).inSeconds > 10),
        );
      }
      _resultHandler(response);
    } else if (message.type == MessageType.MESSAGE_TYPE_NOTIFICATION) {
      _notificationHandler(message);
    }
  }

  void _notificationHandler(RpcMessage message) {
    switch (message.notification.whichNotification()) {
      // HSP NOTIFICATIONS
      case Notification_Notification.notificationHspThresholdReached:
        _hspState.value =
            message.notification.notificationHspThresholdReached.state;
        hspThresholdReached?.call(false);
        break;
      case Notification_Notification.notificationHspStateChanged:
        _hspState.value =
            message.notification.notificationHspStateChanged.state;
        break;
      case Notification_Notification.notificationHspLooping:
        _hspState.value = message.notification.notificationHspLooping.state;
        hspLooped?.call();
        break;
      case Notification_Notification.notificationHspStarving:
        _hspState.value = message.notification.notificationHspStarving.state;
        hspThresholdReached?.call(true);
        break;
      case Notification_Notification.notificationHspResumedOnNonStarving:
        _hspState.value =
            message.notification.notificationHspResumedOnNonStarving.state;
        break;
      case Notification_Notification.notificationHspPausedOnStarving:
        _hspState.value =
            message.notification.notificationHspPausedOnStarving.state;
        hspPausedOnStarving?.call();
        break;

      case Notification_Notification.notificationBatteryChanged:
        _batteryState.value =
            message.notification.notificationBatteryChanged.state;
        break;

      // UNHANDLED NOTIFICATION
      default:
        if (kDebugMode) debugPrint(message.notification.toDebugString());
        break;
    }
  }

  Future<Response?> _sendRequestFuture(Request request) async {
    request.id = messageId;
    final message = RpcMessage(
      type: MessageType.MESSAGE_TYPE_REQUEST,
      request: request,
    );
    final completer = Completer<Response>();
    _messageCompleters.add(
      _PendingRequest(request.id, DateTime.now(), completer),
    );
    _worker.sendToSerialize(message);
    return completer.future.timeout(Duration(seconds: 5));
  }

  void _sendRequest(Request request) {
    if (kDebugMode) debugPrint(request.whichParams().toString());
    request.id = noCompletionId;
    final message = RpcMessage(
      type: MessageType.MESSAGE_TYPE_REQUEST,
      request: request,
    );
    _worker.sendToSerialize(message);
  }

  Future<void> dispose() async {
    effectDispose();
    _batteryPolling?.cancel();
    _disconnectDebounceTimer?.cancel();
    _waitingForManualDisconnectAck = true;
    _manualDisconnectAckCompleter = Completer<void>();
    try {
      await Future.delayed(const Duration(milliseconds: 300));
      await _device.device.disconnect();
      // If the device already reported a disconnect, the status callback was
      // consumed by the debounce path and will never fire again — complete
      // the ack locally instead of stalling until the timeout. This keeps
      // teardown (and thus auto-reconnect) fast after a real connection loss.
      if (_disconnectEventSeen) {
        _disconnectDebounceTimer?.cancel();
        _disconnectDebounceTimer = null;
        _isConnected.value = false;
        _manualDisconnectAckCompleter?.complete();
      }
      // Manual disconnect must be reflected by the device status callback
      // first; wait for the ack so _isConnected flips to false cleanly
      // rather than racing the debounce timer.
      try {
        await _manualDisconnectAckCompleter!.future.timeout(
          _manualDisconnectAckTimeout,
        );
      } on TimeoutException {
        Logger.warning(
          "Timed out waiting for BLE disconnect ack from device stream.",
        );
      }

      await _connectionSubscription.cancel();
      await _device.rx.notifications.unsubscribe();
      await _device.rx.unsubscribe();

      await _bufferReceivedSubscription.cancel();
      await _deserializeSubscription.cancel();
      await _serializeSubscription.cancel();
      await _worker.dispose();
    } catch (e) {
      debugPrint("Error during BLE dispose: $e");
    } finally {
      _waitingForManualDisconnectAck = false;
      _manualDisconnectAckCompleter = null;
    }
  }

  Future<(int, int)?> sliderStrokeGet() async {
    final request = RequestSliderStrokeGet();
    final response = await _sendRequestFuture(
      Request(requestSliderStrokeGet: request),
    );
    if (response != null && response.hasResponseSliderStrokeGet()) {
      final get = response.responseSliderStrokeGet;
      final min = (get.min * 100.0).round().clamp(0, 100);
      final max = (get.max * 100.0).round().clamp(0, 100);
      return (min, max);
    }
    return null;
  }

  Future<(int, int)?> sliderStrokeSet(int min, int max) async {
    final request = RequestSliderStrokeSet(
      min: (min / 100.0).clamp(0.0, 1.0),
      max: (max / 100.0).clamp(0.0, 1.0),
    );
    final response = await _sendRequestFuture(
      Request(requestSliderStrokeSet: request),
    );
    if (response != null && response.hasResponseSliderStrokeSet()) {
      final get = response.responseSliderStrokeSet;
      final min = (get.min * 100.0).round().clamp(0, 100);
      final max = (get.max * 100.0).round().clamp(0, 100);
      return (min, max);
    }
    return null;
  }

  Future<HspState?> hspStateGet() async {
    final request = RequestHspStateGet();
    final response = await _sendRequestFuture(
      Request(requestHspStateGet: request),
    );
    if (response != null && response.hasResponseHspStateGet()) {
      final hspState = response.responseHspStateGet.state;
      return hspState;
    }
    return null;
  }

  @override
  void positionWithDuration(double relPos, int moveOverTimeMs) {
    final request = RequestHdspXpTSet(
      xp: relPos,
      t: moveOverTimeMs,
      stopOnTarget: true,
    );
    _sendRequest(Request(requestHdspXpTSet: request));
  }

  void _resultHandler(Response response) {
    switch (response.whichResult()) {
      case Response_Result.responseHspStateGet:
        _hspState.value = response.responseHspStateGet.state;
        break;
      case Response_Result.responseHspSetup:
        _hspState.value = response.responseHspSetup.state;
        break;
      case Response_Result.responseHspFlush:
        _hspState.value = response.responseHspFlush.state;
        break;
      case Response_Result.responseHspAdd:
        _hspState.value = response.responseHspAdd.state;
        break;
      case Response_Result.responseHspPlay:
        _hspState.value = response.responseHspPlay.state;
        break;
      case Response_Result.responseHspResume:
        _hspState.value = response.responseHspResume.state;
        break;
      case Response_Result.responseHspPause:
        _hspState.value = response.responseHspPause.state;
        break;
      case Response_Result.responseHspCurrentTimeSet:
        _hspState.value = response.responseHspCurrentTimeSet.state;
        break;
      case Response_Result.responseHspLoopSet:
        _hspState.value = response.responseHspLoopSet.state;
        break;
      case Response_Result.responseHspStop:
        _hspState.value = response.responseHspStop.state;
        break;
      default:
    }
  }

  @override
  void hspSetup({int? streamId}) {
    streamId ??= Random().nextInt(maxInt32);
    final request = RequestHspSetup(streamId: streamId);
    _sendRequest(Request(requestHspSetup: request));
  }

  @override
  void hspFlush() {
    final request = RequestHspFlush();
    _sendRequest(Request(requestHspFlush: request));
  }

  @override
  void hspAdd(
    List<FunscriptAction> points, {
    required bool flush,
    required int? tailPointStreamIndex,
    required int? tailPointThreshold,
  }) {
    final request = RequestHspAdd(
      points: points.map((a) => Point(t: a.at, x: a.pos)).toList(),
      flush: flush,
      tailPointStreamIndex: tailPointStreamIndex,
      tailPointThreshold: tailPointThreshold,
    );
    _sendRequest(Request(requestHspAdd: request));
  }

  @override
  void hspPlay({
    required int startTime,
    required double playbackRate,
    required bool loop,
    required bool pauseOnStarving,
  }) {
    final request = RequestHspPlay(
      startTime: startTime,
      loop: loop,
      pauseOnStarving: pauseOnStarving,
      playbackRate: playbackRate,
      serverTime: Int64(serverTime()),
    );
    _sendRequest(Request(requestHspPlay: request));
  }

  @override
  void hspResume() {
    final request = RequestHspResume(pickUp: false);
    _sendRequest(Request(requestHspResume: request));
  }

  @override
  void hspPause() {
    final request = RequestHspPause();
    _sendRequest(Request(requestHspPause: request));
  }

  @override
  void hspCurrentTimeSet({required int currentTime, required double filter}) {
    final request = RequestHspCurrentTimeSet(
      currentTime: currentTime,
      serverTime: Int64(serverTime()),
      filter: filter,
    );
    _sendRequest(Request(requestHspCurrentTimeSet: request));
  }

  @override
  void hspStop() {
    final request = RequestHspStop();
    _sendRequest(Request(requestHspStop: request));
  }

  @override
  void hspLoop(bool loop) {
    final request = RequestHspLoopSet(loop: loop);
    _sendRequest(Request(requestHspLoopSet: request));
  }

  Future<ResponseClockOffsetGet?> getClockOffset() async {
    final request = RequestClockOffsetGet();
    final response = await _sendRequestFuture(
      Request(requestClockOffsetGet: request),
    );
    if (response != null && response.hasResponseClockOffsetGet()) {
      final get = response.responseClockOffsetGet;
      return get;
    }
    return null;
  }

  Future<ResponseClockOffsetSet?> setClockOffset(int offset, {int? rtd}) async {
    final request = RequestClockOffsetSet(clockOffset: Int64(offset), rtd: rtd);
    final response = await _sendRequestFuture(
      Request(requestClockOffsetSet: request),
    );
    if (response != null && response.hasResponseClockOffsetSet()) {
      final set = response.responseClockOffsetSet;
      return set;
    }
    return null;
  }

  Future<ResponseCapabilitiesGet?> getCapabilities() async {
    final request = RequestCapabilitiesGet();
    final response = await _sendRequestFuture(
      Request(requestCapabilitiesGet: request),
    );
    if (response != null && response.hasResponseCapabilitiesGet()) {
      final caps = response.responseCapabilitiesGet;
      return caps;
    }
    return null;
  }

  Future<BatteryState?> getBatteryState() async {
    final request = RequestBatteryGet();
    final response = await _sendRequestFuture(
      Request(requestBatteryGet: request),
    );
    if (response != null && response.hasResponseBatteryGet()) {
      final state = response.responseBatteryGet.state;
      return state;
    }
    return null;
  }
}
