import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/logging.dart';
import 'package:syncopathy/notification_feed.dart';
import 'package:window_manager/window_manager.dart';

/// Owns the native Windows Graphics Capture session that mirrors mpv's own
/// `vo=gpu-next` window into a Flutter external texture.
///
/// The mpv window stays behind the Flutter window, sized and positioned to the
/// video widget's on-screen rectangle. The captured texture is then drawn by
/// Flutter like any other image, so the app's controls and settings overlays
/// keep working on top of it.
class NativeMpvCapture with WindowListener {
  NativeMpvCapture(
    this._player, {
    required bool Function() isPlaybackActive,
    required bool Function() hasMedia,
    ReadonlySignal<int>? layoutSignal,
  }) : _isPlaybackActive = isPlaybackActive,
       _hasMedia = hasMedia {
    WindowManager.instance.addListener(this);
    _observeWindowId();
    _observePath();
    _observeEof();
    _pollWindowId();
    if (layoutSignal != null) {
      // The player page can be pushed by a PageView slide. During that slide
      // the video widget reports transient (sometimes off-screen) rectangles;
      // measure repeatedly for a moment after each page change so capture only
      // starts once the rectangle has settled.
      _layoutEffectDispose = effect(() {
        layoutSignal.value;
        _kickLayoutBurst();
      });
    }
  }

  static const MethodChannel _channel = MethodChannel('syncopathy/mpv_capture');

  final NativePlayer _player;

  /// Whether frames are currently expected: a video is loaded and playback is
  /// not paused. Used by the stall watchdog so it never restarts while idle.
  final bool Function() _isPlaybackActive;

  /// Whether anything is loaded at all.
  ///
  /// Capture must not be created against an idle mpv window: the capture item
  /// built then reports no content size and delivers only a couple of frames
  /// per second, and it stays that way after a video is opened — the picture
  /// then looks like a still image. A session created while a video is loaded
  /// is healthy, so starting is deferred until there is one.
  final bool Function() _hasMedia;

  /// Texture ID returned by the native plugin, or null while capture has not
  /// started (or is stopped because the app is minimized).
  final Signal<int?> textureId = signal(null);

  /// Bumped whenever the app window moves/resizes/fullscreens, so every
  /// mounted capture surface re-measures its rectangle.
  final Signal<int> measureTick = signal(0);

  Rect? _lastRect;
  double _lastDpr = 1.0;
  Size? _lastAppliedSize;
  int? _windowId;
  bool _started = false;
  bool _starting = false;
  bool _applying = false;
  bool _applyingAgain = false;
  bool _disposed = false;
  bool _minimized = false;
  bool _alerted = false;
  bool _restarting = false;

  /// Whether capture has ever succeeded in this session. A later failure is a
  /// recovery, not a first-time setup problem, and must not raise the "capture
  /// could not start" alert: that text tells the user to turn the feature off,
  /// which is the wrong advice for a session that already worked.
  bool _everStarted = false;

  // Mirrored from mpv, so the frame watchdog only acts while frames are
  // actually expected. A finished video legitimately produces none.
  bool _eof = false;

  Timer? _windowIdPoll;
  Timer? _resizeTimer;
  Timer? _retryTimer;
  Timer? _watchdogTimer;
  Timer? _layoutBurstTimer;
  Timer? _startSettleTimer;
  Timer? _followTimer;
  void Function()? _layoutEffectDispose;
  Rect? _pendingStartRect;
  double _pendingStartDpr = 1.0;
  int _startAttempts = 0;
  int _boundsFailures = 0;
  int? _lastFrameCount;
  int? _lastArrivedCount;
  int _stalledChecks = 0;
  int _stallRestarts = 0;
  int _captureGeneration = 0;

  Widget buildSurface() => NativeMpvCaptureSurface(capture: this);

  /// Called by each mounted [NativeMpvCaptureSurface] with its rectangle in
  /// logical Flutter coordinates. Only the currently visible route's surface
  /// is allowed to update the native window.
  void setBounds(Rect rect, double devicePixelRatio) {
    if (_disposed || _minimized) return;
    if (rect.width <= 0 || rect.height <= 0) return;
    if (_started && _lastRect == rect && _lastDpr == devicePixelRatio) {
      return;
    }
    final sizeChanged = _lastAppliedSize != rect.size;
    _lastRect = rect;
    _lastDpr = devicePixelRatio;

    if (!_started) {
      // A failed start schedules a retry; don't let every rebuild of the
      // surface bypass that delay with an immediate new attempt. Also wait
      // until the rectangle has stopped moving: during the first PageView
      // transition to the player tab it slides in across several frames,
      // and starting at one of those positions is what made the mpv window
      // briefly visible at the wrong place.
      if (!_starting && _retryTimer == null) {
        _scheduleStartSettle(rect, devicePixelRatio);
      }
      return;
    }

    if (sizeChanged) {
      // Resizing recreates the frame pool. Debounce it so dragging a window
      // edge does not do that every frame; 150ms still fired mid-drag whenever
      // the pointer paused, and each restart froze the frame stream.
      //
      // A large jump (leaving or entering fullscreen) is not a drag: the
      // native window stays at the old size until this is applied, and while
      // the app window is smaller than it the mpv window would hang outside
      // it. Apply those immediately.
      final previousSize = _lastAppliedSize;
      final isLargeJump =
          previousSize != null &&
          (rect.width - previousSize.width).abs() > previousSize.width * 0.25;
      _resizeTimer?.cancel();
      if (isLargeJump) {
        _resizeTimer = null;
        unawaited(_applyBounds());
      } else {
        _resizeTimer = Timer(const Duration(milliseconds: 250), () {
          _resizeTimer = null;
          unawaited(_applyBounds());
        });
      }
    } else {
      // Position-only changes are cheap; move the hidden mpv window now so it
      // stays under the video while the app window is dragged.
      unawaited(_applyBounds());
    }
  }

  /// Starts the capture only after the reported rectangle has not moved for a
  /// short interval. This filters out the transient positions a PageView slide
  /// (or a window animation) produces before the video page has settled.
  void _scheduleStartSettle(Rect rect, double dpr) {
    if (_disposed ||
        _minimized ||
        _started ||
        _starting ||
        _retryTimer != null) {
      return;
    }
    if (_pendingStartRect == rect && _pendingStartDpr == dpr) {
      // The same rectangle has already been scheduled; keep the existing
      // countdown rather than restarting it on every measurement.
      return;
    }
    _pendingStartRect = rect;
    _pendingStartDpr = dpr;
    _startSettleTimer?.cancel();
    _startSettleTimer = Timer(const Duration(milliseconds: 100), () {
      _startSettleTimer = null;
      if (_disposed ||
          _minimized ||
          _started ||
          _starting ||
          _retryTimer != null) {
        return;
      }
      unawaited(_tryStart());
    });
  }

  /// Increments [measureTick] a few times after a page change so every mounted
  /// capture surface re-measures while the PageView slide is still running and
  /// once more after it has finished.
  void _kickLayoutBurst() {
    if (_disposed) return;
    _layoutBurstTimer?.cancel();
    var ticks = 0;
    // No signal write here: this runs inside an effect that reads the page
    // signal, and incrementing (which reads first) would make the effect
    // depend on measureTick and write to its own dependency, tripping the
    // signals cycle detector. The periodic ticks below run outside the effect.
    _layoutBurstTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      measureTick.value++;
      ticks++;
      if (ticks >= 9) {
        timer.cancel();
        _layoutBurstTimer = null;
      }
    });
  }

  Future<void> _tryStart() async {
    if (_disposed || _minimized || _starting || _started) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_hasMedia()) {
      // Nothing is loaded yet. The path observer starts the capture once a
      // video arrives; building it against an idle window produces a session
      // that barely delivers frames afterwards.
      return;
    }
    final windowId = _windowId;
    final rect = _lastRect;
    if (windowId == null || rect == null) return;
    if (rect.width <= 0 || rect.height <= 0) return;

    _starting = true;
    try {
      final texture = await _channel.invokeMethod<int>(
        'start',
        _arguments(windowId, rect, _lastDpr),
      );
      if (texture == null || texture <= 0) {
        throw StateError('Native capture returned no texture');
      }
      if (_disposed) return;
      _started = true;
      _everStarted = true;
      _startAttempts = 0;
      _boundsFailures = 0;
      _lastAppliedSize = rect.size;
      _captureGeneration++;
      _startSettleTimer?.cancel();
      _startSettleTimer = null;
      _pendingStartRect = null;
      textureId.value = texture;
      _startWatchdog();
      Logger.info('Native mpv capture started (texture $texture)');
    } catch (error, stack) {
      _startAttempts++;
      Logger.error(
        'Native mpv capture failed (attempt $_startAttempts)',
        error,
        stack,
      );
      // The mpv window can still be hidden/transitioning when the first
      // window-id event arrives. Retry briefly instead of requiring a resize,
      // and only raise the alert once those retries are exhausted.
      if (!_disposed && !_minimized && _startAttempts <= 5) {
        _retryTimer = Timer(const Duration(seconds: 2), () {
          _retryTimer = null;
          unawaited(_tryStart());
        });
      } else if (!_alerted && !_everStarted) {
        // Only a session that never worked at all gets the "turn the feature
        // off" advice. A capture that worked and then lost its session recovers
        // through the watchdog or the next bounds update; telling the user to
        // disable the feature there would be wrong and would hide the retry.
        _alerted = true;
        AlertManager.showError(
          'Embedded mpv capture could not start. Turn off "Use mpv Native '
          'Capture" in Settings if this persists.',
          stack,
        );
      } else {
        // Keep trying at a slower cadence instead of giving up silently.
        _retryTimer = Timer(const Duration(seconds: 5), () {
          _retryTimer = null;
          unawaited(_tryStart());
        });
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _applyBounds() async {
    if (_disposed || !_started) return;
    final rect = _lastRect;
    if (rect == null) return;
    if (_applying) {
      _applyingAgain = true;
      return;
    }

    final generation = _captureGeneration;
    _applying = true;
    try {
      await _channel.invokeMethod<void>(
        'updateBounds',
        _arguments(_windowId ?? 0, rect, _lastDpr),
      );
      _lastAppliedSize = rect.size;
      _boundsFailures = 0;
    } catch (error, stack) {
      // A restart that was already underway owns the capture now.
      if (_captureGeneration != generation) return;
      // The native side can refuse a bounds update for a reason that fixes
      // itself (a resize arriving while its frame pool is being recreated).
      // Rebuilding the whole session for the first refusal is what made a
      // window drag drop the picture; only a repeat makes it a lost session.
      _boundsFailures++;
      if (_boundsFailures < 2) {
        Logger.warning('Native mpv capture bounds update failed; retrying');
        _resizeTimer?.cancel();
        _resizeTimer = Timer(const Duration(milliseconds: 250), () {
          _resizeTimer = null;
          unawaited(_applyBounds());
        });
        return;
      }
      // The native side loses its window across some lifecycle transitions.
      // Drop the texture and try to establish a fresh capture session.
      Logger.error('Native mpv capture bounds update failed', error, stack);
      _started = false;
      _lastAppliedSize = null;
      _boundsFailures = 0;
      textureId.value = null;
      unawaited(_tryStart());
    } finally {
      _applying = false;
      if (_applyingAgain) {
        _applyingAgain = false;
        unawaited(_applyBounds());
      }
    }
  }

  Map<String, Object> _arguments(int windowId, Rect rect, double dpr) {
    return <String, Object>{
      'windowId': windowId,
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
      'devicePixelRatio': dpr,
    };
  }

  Future<void> _stopCapture({bool hideWindow = true}) async {
    _started = false;
    _captureGeneration++;
    _lastAppliedSize = null;
    _boundsFailures = 0;
    _lastFrameCount = null;
    _lastArrivedCount = null;
    _stalledChecks = 0;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _followTimer?.cancel();
    _followTimer = null;
    _startSettleTimer?.cancel();
    _startSettleTimer = null;
    _pendingStartRect = null;
    textureId.value = null;
    try {
      await _channel.invokeMethod<void>('stop', {
        'hideWindow': hideWindow,
      });
    } catch (_) {
      // Stopping is best-effort; the native side also tears down with the
      // player window.
    }
  }

  /// Restarts the capture session after it stopped delivering frames.
  ///
  /// A stalled Windows Graphics Capture session keeps its last texture on
  /// screen, so the video looks frozen while the clock keeps running. Recreating
  /// the session restores the stream without touching playback or mpv itself.
  ///
  /// The mpv window is left visible: hiding it and showing it again immediately
  /// makes mpv stop presenting to it, which is exactly the state a restart is
  /// meant to recover from.
  Future<void> _restartCapture() async {
    if (_disposed || _minimized || _restarting) return;
    _restarting = true;
    try {
      await _stopCapture(hideWindow: false);
      _startAttempts = 0;
      await _tryStart();
    } finally {
      _restarting = false;
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _lastFrameCount = null;
    _lastArrivedCount = null;
    _stalledChecks = 0;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_checkCaptureHealth());
    });
  }

  Future<void> _checkCaptureHealth() async {
    bool playbackActive;
    try {
      playbackActive = _isPlaybackActive();
    } catch (_) {
      // The player signals may not be initialized yet on the first ticks.
      return;
    }
    if (_disposed ||
        !_started ||
        _minimized ||
        _restarting ||
        !playbackActive ||
        _eof) {
      _stalledChecks = 0;
      _lastFrameCount = null;
      _lastArrivedCount = null;
      return;
    }
    Map<Object?, Object?>? info;
    try {
      info = await _channel.invokeMethod<Map<Object?, Object?>>(
        'diagnostics',
      );
    } catch (_) {
      // The channel can disappear while the engine tears down.
      return;
    }
    if (_disposed || !_started || info == null) return;
    final copied = (info['copied'] as num?)?.toInt();
    final arrived = (info['arrived'] as num?)?.toInt();
    if (copied == null || arrived == null) return;
    // Either a copied frame or a WGC callback counts as progress. A session
    // that still raises callbacks is alive even if the delivered rate is low;
    // only one that has gone completely quiet is worth rebuilding.
    if (_lastFrameCount == null ||
        _lastArrivedCount == null ||
        copied != _lastFrameCount ||
        arrived != _lastArrivedCount) {
      _lastFrameCount = copied;
      _lastArrivedCount = arrived;
      _stalledChecks = 0;
      _stallRestarts = 0;
      return;
    }
    _stalledChecks++;
    if (_stalledChecks == 1) {
      // Log what the native side sees before giving the watchdog its decision:
      // whether WGC raises callbacks at all is what distinguishes a dead
      // session from a size mismatch.
      if (!_disposed) {
        Logger.warning('Native mpv capture diagnostics: $info');
      }
    }
    if (_stalledChecks < 3) return;
    _stalledChecks = 0;
    Logger.warning('Native mpv capture stopped advancing; restarting it');
    // A second consecutive stall after a fresh capture session usually means
    // the video output itself stopped presenting. A zero-distance relative
    // seek asks mpv to re-present the current frame without moving playback.
    if (_stallRestarts >= 1) {
      try {
        await _player.command(['seek', '0', 'relative']);
      } catch (_) {
        // Playback recovery is best-effort; the capture restart still runs.
      }
    }
    _stallRestarts++;
    await _restartCapture();
  }

  /// Opening or switching a file makes mpv rebuild its video output. The
  /// capture item is bound to the window, which mpv keeps across files, so the
  /// session itself survives; only the stall bookkeeping is reset.
  ///
  /// Rebuilding the session here used to be the recovery for a frozen picture,
  /// but a rebuild issued while mpv is still reconfiguring its output produced
  /// a session that delivered a couple of frames per second — the watchdog then
  /// restarted it every 3 seconds, which is what made switching videos look
  /// like a still image. A session that is genuinely dead is still recovered by
  /// the watchdog, at a point where the video output has settled.
  void _observePath() {
    unawaited(
      _player
          .observeProperty('path', (value) async {
            if (_disposed || _minimized) return;
            if (value.trim().isEmpty) return;
            _stalledChecks = 0;
            _lastFrameCount = null;
            _lastArrivedCount = null;
            _stallRestarts = 0;
            // Capture is deferred while nothing is loaded, so this is the
            // moment it becomes worth starting.
            if (!_started && !_starting && _retryTimer == null) {
              final rect = _lastRect;
              if (rect != null) _scheduleStartSettle(rect, _lastDpr);
            }
          })
          .catchError((Object error, StackTrace stack) {
            Logger.error('Could not observe mpv path', error, stack);
          }),
    );
  }

  void _observeEof() {
    // `pause` is already observed by the player itself, and observeProperty
    // rejects an already-observed property, so playback activity is supplied
    // through [_isPlaybackActive] instead of a second observer here.
    unawaited(
      _player
          .observeProperty('eof-reached', (value) async {
            _eof = value.trim() == 'yes';
          })
          .catchError((Object error, StackTrace stack) {
            Logger.error('Could not observe mpv eof-reached', error, stack);
          }),
    );
  }

  void _observeWindowId() {
    unawaited(
      _player
          .observeProperty('window-id', (value) async {
            final id = int.tryParse(value.trim());
            if (id == null || id <= 0) return;
            if (_windowId == id) return;
            if (_windowId != null && _started) {
              // mpv recreated its window; the old capture is bound to the
              // previous HWND, so tear it down before starting on the new one.
              await _stopCapture();
            }
            _startAttempts = 0;
            _windowId = id;
            // media_kit's external window may already be visible at its default
            // position; hide it until capture has placed it behind the video.
            try {
              await _channel.invokeMethod<void>('hide', {'windowId': id});
            } catch (_) {}
            // Only start once a video surface has reported a rectangle; the
            // first player-page visit does that after the PageView settles.
            final rect = _lastRect;
            if (rect != null) _scheduleStartSettle(rect, _lastDpr);
          })
          .catchError((Object error, StackTrace stack) {
            Logger.error('Could not observe mpv window-id', error, stack);
          }),
    );
  }

  void _pollWindowId() {
    _windowIdPoll = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (_disposed) {
        timer.cancel();
        return;
      }
      if (_windowId != null) {
        timer.cancel();
        return;
      }
      try {
        final value = await _player.getProperty('window-id');
        if (_disposed) return;
        // The property observer may have reported the same window while this
        // query was in flight; it owns the hide/start sequence then. Without
        // this check the late poll could hide the window again right after the
        // capture session started, which stops dragging new frames into Flutter.
        if (_windowId != null) {
          timer.cancel();
          return;
        }
        final id = int.tryParse(value.trim());
        if (id != null && id > 0) {
          timer.cancel();
          _windowId = id;
          unawaited(
            _channel
                .invokeMethod<void>('hide', {'windowId': id})
                .catchError((_) {}),
          );
          final rect = _lastRect;
          if (rect != null) _scheduleStartSettle(rect, _lastDpr);
        }
      } catch (_) {
        // Player may still be initializing; the next tick retries.
      }
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _windowIdPoll?.cancel();
    _resizeTimer?.cancel();
    _retryTimer?.cancel();
    _watchdogTimer?.cancel();
    _layoutBurstTimer?.cancel();
    _startSettleTimer?.cancel();
    _followTimer?.cancel();
    _layoutEffectDispose?.call();
    WindowManager.instance.removeListener(this);
    unawaited(_stopCapture());
    for (final property in const ['window-id', 'path', 'eof-reached']) {
      try {
        await _player.unobserveProperty(property);
      } catch (_) {
        // The player may already be disposed, or the property was never
        // successfully observed.
      }
    }
    textureId.dispose();
    measureTick.dispose();
  }

  // ---- window_manager lifecycle --------------------------------------------

  @override
  void onWindowMinimize() {
    _minimized = true;
    unawaited(_stopCapture());
  }

  @override
  void onWindowRestore() {
    _minimized = false;
    final rect = _lastRect;
    if (rect != null) {
      _scheduleStartSettle(rect, _lastDpr);
    } else {
      unawaited(_tryStart());
    }
    _bumpMeasure();
  }

  @override
  void onWindowMove() {
    // The native side repositions the mpv window from inside the app window's
    // own WM_WINDOWPOSCHANGED, so both windows land on the same compositor
    // frame. This is only a safety net for a hook that could not be installed,
    // and it is debounced to one call per pause instead of one per mouse event.
    if (_resizeTimer != null) return;
    _followTimer?.cancel();
    _followTimer = Timer(const Duration(milliseconds: 120), () {
      _followTimer = null;
      if (_disposed || !_started || _resizeTimer != null) return;
      unawaited(_applyBounds());
    });
  }

  @override
  void onWindowMoved() {
    // The rectangle is expressed in the Flutter view's coordinates, so moving
    // the app window does not change it and re-measuring would only rebuild the
    // video surface. One final bounds update snaps the native window to the
    // settled position.
    if (_resizeTimer != null) return;
    _followTimer?.cancel();
    _followTimer = null;
    unawaited(_applyBounds());
  }

  @override
  void onWindowResize() => _bumpMeasure();

  @override
  void onWindowResized() => _bumpMeasure();

  @override
  void onWindowMaximize() => _bumpMeasure();

  @override
  void onWindowUnmaximize() => _bumpMeasure();

  @override
  void onWindowEnterFullScreen() => _bumpMeasure();

  @override
  void onWindowLeaveFullScreen() => _bumpMeasure();

  void _bumpMeasure() {
    if (_disposed) return;
    measureTick.value++;
  }
}

/// Draws the native capture texture and reports its on-screen rectangle to the
/// capture session. Only the route that is currently on top may update the
/// hidden mpv window; otherwise the normal player page would fight the
/// fullscreen page over the same rectangle.
class NativeMpvCaptureSurface extends StatefulWidget {
  const NativeMpvCaptureSurface({super.key, required this.capture});

  final NativeMpvCapture capture;

  @override
  State<NativeMpvCaptureSurface> createState() =>
      _NativeMpvCaptureSurfaceState();
}

class _NativeMpvCaptureSurfaceState extends State<NativeMpvCaptureSurface> {
  final GlobalKey _key = GlobalKey();

  // The route's own transition (entering/leaving fullscreen) and that of the
  // route above it. Both distort the measured rectangle frame by frame; the
  // capture session must not be restarted for every intermediate size.
  Animation<double>? _routeAnimation;
  Animation<double>? _routeSecondaryAnimation;
  bool _measureScheduled = false;
  bool _routeSettledMeasurePending = false;
  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachRouteListeners();
    _scheduleMeasure();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _routeAnimation?.removeStatusListener(_onRouteStatusChanged);
    _routeSecondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
    super.dispose();
  }

  void _attachRouteListeners() {
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    final secondaryAnimation = route?.secondaryAnimation;
    if (identical(animation, _routeAnimation) &&
        identical(secondaryAnimation, _routeSecondaryAnimation)) {
      return;
    }
    _routeAnimation?.removeStatusListener(_onRouteStatusChanged);
    _routeSecondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
    _routeAnimation = animation;
    _routeSecondaryAnimation = secondaryAnimation;
    animation?.addStatusListener(_onRouteStatusChanged);
    secondaryAnimation?.addStatusListener(_onRouteStatusChanged);
  }

  void _onRouteStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      if (_routeSettledMeasurePending) {
        _routeSettledMeasurePending = false;
        _scheduleMeasure();
      }
    }
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _measure();
    });
  }

  /// Re-measures once the current route transition has finished. A timeout is
  /// used in addition to the animation status listeners so a route that is
  /// replaced mid-transition can never leave the capture bounds stranded.
  void _deferMeasure() {
    _routeSettledMeasurePending = true;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 200), () {
      _settleTimer = null;
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null ||
          (route.isCurrent &&
              !(route.animation?.isAnimating ?? false) &&
              !(route.secondaryAnimation?.isAnimating ?? false))) {
        _routeSettledMeasurePending = false;
        _scheduleMeasure();
      } else if (route.isCurrent) {
        _deferMeasure();
      }
      // Not current: the route status listener schedules the measurement when
      // the covering route is gone.
    });
  }

  void _measure() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      // The covering route owns the video now; re-measure when it has gone.
      _routeSettledMeasurePending = true;
      return;
    }
    if (route?.animation?.isAnimating ?? false) {
      _deferMeasure();
      return;
    }
    if (route?.secondaryAnimation?.isAnimating ?? false) {
      _deferMeasure();
      return;
    }

    final element = _key.currentContext;
    if (element == null) return;
    final box = element.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return;

    final rect = box.localToGlobal(Offset.zero) & box.size;
    final viewRect = Offset.zero & MediaQuery.sizeOf(context);
    final visibleRect = rect.intersect(viewRect);
    // A rect this small is a transient layout, not a video area. Applying it
    // used to resize the mpv window to a few pixels, which then had to be
    // rebuilt back up — the capture never settled.
    if (rect.width < 32.0 || rect.height < 32.0) {
      _routeSettledMeasurePending = true;
      return;
    }
    // A PageView still sliding the player page in lays the video out at
    // transient positions, sometimes entirely outside the view. Showing the
    // mpv window there is what produced the visible standalone mpv window
    // flash. Wait until the whole video rectangle is on screen; the layout
    // burst re-measures until it is.
    if (visibleRect.isEmpty ||
        visibleRect.width < rect.width - 1.0 ||
        visibleRect.height < rect.height - 1.0) {
      _routeSettledMeasurePending = true;
      return;
    }

    _routeSettledMeasurePending = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    widget.capture.setBounds(rect, MediaQuery.devicePixelRatioOf(context));
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return SignalBuilder(
      builder: (context) {
        // Track both the texture and window-layout changes.
        final textureId = widget.capture.textureId.value;
        widget.capture.measureTick.value;
        _scheduleMeasure();
        return SizedBox.expand(
          key: _key,
          child: textureId == null
              ? const ColoredBox(color: Color(0xFF000000))
              : Texture(
                  textureId: textureId,
                  filterQuality: FilterQuality.medium,
                ),
        );
      },
    );
  }
}
