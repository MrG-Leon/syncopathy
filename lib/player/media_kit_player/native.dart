import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide Video;
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/ioc.dart';
import 'package:syncopathy/player/media_kit_player/media_kit_video_player.dart';
import 'package:syncopathy/player/media_kit_player/native_mpv_capture.dart';

/// One-time initialization of the playback engine, before any player is built.
void initPlaybackEngine() => MediaKit.ensureInitialized();

class MediaKitPlayerImpl extends MediaKitVideoPlayer {
  @override
  ReadonlySignal<bool> get paused => _paused;
  final Signal<bool> _paused = signal(false);

  @override
  Future<double?> queryDuration() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return null;
    try {
      // Empty while the file is still opening.
      return double.tryParse(await platform.getProperty('duration'));
    } catch (_) {
      return null;
    }
  }

  /// Last value written to mpv, so the reactive re-apply below can skip writes
  /// that would change nothing.
  String _appliedHwdec;

  NativeMpvCapture? _capture;

  MediaKitPlayerImpl({
    required super.embeddedPlayer,
    bool useNativeMpvCapture = false,
    required ReadonlySignal<String> hwdec,
  }) : _appliedHwdec = hwdec.value {
    final useCapture = embeddedPlayer && useNativeMpvCapture;
    player = Player(
      configuration: PlayerConfiguration(
        osc: useCapture ? false : !embeddedPlayer,
        externalWindow: !embeddedPlayer || useCapture,
        aditionalLibMpvOptions: {
          'config': 'yes',
          // Point mpv at our app-owned config dir (set during platform init)
          // so it uses our mpv.conf/input.conf rather than the user's global
          // mpv configuration. Empty string falls back to mpv's defaults.
          'config-dir': mpvConfigDir ?? '',
          'input-default-bindings': useCapture ? 'no' : 'yes',
          // Only takes effect for the external window, where there is no
          // VideoController; the embedded path is governed by the controller
          // configuration below, which mpv applies later and thus wins.
          'hwdec': _appliedHwdec,
          'border': useCapture ? 'no' : 'yes',
          'geometry': "1280x720",
          'idle': 'yes',
          'force-window': embeddedPlayer && !useCapture ? 'no' : 'yes',
          if (useCapture) 'gpu-api': 'd3d11',
          // Windows Graphics Capture stops receiving frames once the captured
          // window is fully covered by the Flutter window, but only with the
          // DXGI flip-model swapchain. The blt-model used by `d3d11-flip=no`
          // keeps presenting while occluded. The capture window is always
          // covered, so this is required rather than an optimisation choice.
          if (useCapture) 'd3d11-flip': 'no',
          if (useCapture) 'input-vo-keyboard': 'no',
          if (useCapture) 'osd-level': '1',
          if (useCapture) 'window-minimized': 'no',
          // mpv resizes its own window to the video's aspect ratio when a file
          // is opened (keepaspect-window). The capture window is sized by us to
          // the Flutter rectangle, so letting mpv adjust it changes the size
          // WGC delivers after the capture textures were built for the
          // requested one — every frame then arrives at an unexpected size and
          // is dropped.
          if (useCapture) 'keepaspect-window': 'no',
        },
        vo: useCapture || !embeddedPlayer ? 'gpu-next' : 'libmpv',
        title: "syncopathy",
      ),
    );
    controller = embeddedPlayer && !useCapture
        ? VideoController(
            player,
            configuration: VideoControllerConfiguration(
              vo: 'libmpv',
              hwdec: _appliedHwdec,
            ),
          )
        : null;

    NativePlayer? nativePlayer;
    if (player.platform is NativePlayer) {
      nativePlayer = player.platform as NativePlayer;
    }
    assert(nativePlayer != null, "Non MPV player not supported");
    if (useCapture && nativePlayer != null) {
      // media_kit's external window is visible by default. Keep it hidden until
      // the capture session has positioned it behind the Flutter video widget.
      nativePlayer.setProperty('osd-level', '1');
      _capture = NativeMpvCapture(
        nativePlayer,
        // Frames are only expected while something is loaded and actually
        // playing. Buffering (including long seeks) legitimately pauses the
        // frame stream, so the watchdog must not treat it as a stall.
        isPlaybackActive: () =>
            loadedPath.value.isNotEmpty && !_paused.value && !buffering.value,
        // Capture is not created against an idle mpv window: the item built
        // then delivers only a few frames per second and stays that way once a
        // video is opened.
        hasMedia: () => loadedPath.value.isNotEmpty,
        // Lets the capture layer re-measure while the player page slides in,
        // so it never starts on a transient rectangle.
        layoutSignal: activePageIndex,
      );
    }
    _paused.value = !player.state.playing;
    // media-kit pause state is weird. listen to mpv directly
    nativePlayer?.observeProperty('pause', (value) async {
      _paused.value = value == 'yes' ? true : false;
    });
    initSignals(player);

    nativePlayer?.setProperty('keep-open', 'yes');
    // Prefetch the next playlist entry so switches don't pay the full load cost.
    nativePlayer?.setProperty('prefetch-playlist', 'yes');
    // Local files don't need the disk-backed cache (meant for network streams).
    nativePlayer?.setProperty('cache-on-disk', 'no');
    nativePlayer?.command(["keybind", "CLOSE_WIN", "ignore"]);
    nativePlayer?.command(["keybind", "q", "ignore"]);

    // Apply later changes to the setting without a restart. `hwdec` is one of
    // mpv's runtime-changeable options, and writing it as a property is the only
    // reliable way to change it: VideoController issues its own hwdec property
    // write once it attaches, after both the init options and mpv.conf have been
    // read, so anything set earlier would be overwritten.
    //
    // The first run is a no-op because _appliedHwdec already holds the value
    // baked into the configuration above.
    final mpv = nativePlayer;
    if (mpv != null) {
      effectAdd([
        effect(() {
          final value = hwdec.value;
          if (value == _appliedHwdec) return;
          _appliedHwdec = value;
          mpv.setProperty('hwdec', value);
        }),
      ]);
    }
  }

  @override
  Widget? buildVideoSurface() {
    final capture = _capture;
    if (capture != null) return capture.buildSurface();
    return super.buildVideoSurface();
  }

  @override
  void dispose() async {
    await _capture?.dispose();
    super.dispose();
  }
}
