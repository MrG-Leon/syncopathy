import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/fullscreen_controller.dart';
import 'package:syncopathy/fullscreen_video_page.dart';
import 'package:syncopathy/helper/constants.dart';
import 'package:syncopathy/helper/effect_dispose_mixin.dart';
import 'package:syncopathy/helper/extensions.dart';
import 'package:syncopathy/helper/throttler.dart';
import 'package:syncopathy/ioc.dart';
import 'package:syncopathy/model/player_model.dart';
import 'package:syncopathy/model/settings_model.dart';
import 'package:syncopathy/player/playback_session.dart';
import 'package:syncopathy/player/script_player_settings.dart';
import 'package:syncopathy/player/video_player.dart';
import 'package:syncopathy/scrolling_graph.dart';
import 'package:syncopathy/video_controls.dart';
import 'package:syncopathy/settings_overlay.dart';

class VideoWidget extends StatefulWidget {
  final VideoPlayer player;
  final Signal<bool> showFunscriptGraph;
  final Signal<bool> showSettings;
  final Signal<bool> showControls;
  final bool isFullscreen;

  /// Provided by [FullscreenVideoPage] so every exit path from the fullscreen
  /// route funnels through the page's single-shot exit guard (which also
  /// restores the native window).
  final VoidCallback? onRequestExitFullscreen;

  /// Fullscreen-only affordance for opening the media library panel. Kept
  /// inside this widget's hover region: a sibling button above the video
  /// triggers `onExit` as the pointer crosses onto it, which auto-hides the
  /// controls and makes the button impossible to click.
  final VoidCallback? onOpenMediaLibrary;

  const VideoWidget({
    super.key,
    required this.player,
    required this.isFullscreen,
    required this.showFunscriptGraph,
    required this.showSettings,
    required this.showControls,
    this.onRequestExitFullscreen,
    this.onOpenMediaLibrary,
  });

  @override
  State<VideoWidget> createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<VideoWidget> with EffectDispose {
  static const Duration _controlsHideDelay = Duration(seconds: 3);

  Timer? _hideControlsTimer;
  // Pointer move/hover fire rapidly; throttle restarting the (allocating) hide
  // timer instead of cancelling+recreating one per event. The 3s hide window
  // makes ~250ms of imprecision invisible.
  final Throttler _controlsThrottle = Throttler(milliseconds: 250);

  // Fullscreen is a route transition plus a native window transition. A
  // double-click on the button used to push two routes (or pop twice) before
  // the first transition had rendered, leaving capture bounds aimed at a
  // surface that was no longer current. Both directions are now one-shot.
  bool _fullscreenRouteOpen = false;

  @override
  void initState() {
    super.initState();
    _startHideControlsTimer();
    final player = getIt.get<VideoPlayer>();
    effectAdd([
      effect(() {
        final path = player.loadedPath.value;
        if (path.trim() == "") {
          widget.showSettings.value = false;
        }
      }),
    ]);
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _controlsThrottle.dispose();
    super.dispose();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(_controlsHideDelay, () {
      if (mounted) {
        widget.showControls.value = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final settings = context.watch<SettingsModel>();
    final playerModel = context.watch<PlayerModel>();
    final activeSession = context.read<ActivePlaybackSession>();

    return Material(
      child: SignalBuilder(
        builder: (context) {
          final showControls =
              widget.showControls.value ||
              widget.showSettings.value ||
              !settings.embeddedVideoPlayer.value;
          final showSettings = widget.showSettings.value;
          final videoSurface = widget.player.buildVideoSurface();
          // Read here, inside the tracked builder, rather than inside the
          // LayoutBuilder below: reads made during layout are not observed, so
          // a new video with a different aspect ratio would keep the previous
          // video's letterboxing until some unrelated signal rebuilt the page.
          final videoWidth = player.videoWidth.value;
          final videoHeight = player.videoHeight.value;

          return LayoutBuilder(
            builder: (context, constraints) {
              final displayWidth = _computeDisplayWidth(
                constraints,
                videoWidth,
                videoHeight,
              );

              return GestureDetector(
                // Touch has no hover/move to reveal controls, so a tap toggles
                // them. Taps that land on an actual control lose the gesture
                // arena to that control, so this only fires on the video area.
                onTap: _onToggleControls,
                child: Listener(
                  onPointerMove: (_) => _onPointerActivity(),
                  child: MouseRegion(
                    cursor: showControls
                        ? MouseCursor.defer
                        : SystemMouseCursors.none,
                    onExit: (_) => widget.showControls.value = false,
                    onHover: (_) => _onPointerActivity(),
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Stack(
                          children: [
                            if (videoSurface != null)
                              _videoContainer(
                                videoSurface,
                                videoWidth,
                                videoHeight,
                              ),
                            Align(
                              alignment: AlignmentGeometry.bottomCenter,
                              child: _buildOverlayColumn(
                                context,
                                player,
                                activeSession,
                                playerModel,
                                settings,
                                showSettings: showSettings,
                                showControls: showControls,
                                displayWidth: displayWidth,
                              ),
                            ),
                          ],
                        ),
                        if (widget.onOpenMediaLibrary != null)
                          // Shares the controls' auto-hide state: on an idle
                          // mouse it disappears together with the bottom bar.
                          // It sits inside this widget's MouseRegion, so moving
                          // onto it counts as pointer activity and keeps both
                          // visible until the pointer actually rests.
                          _buildMediaLibraryButton(
                            showControls && !showSettings,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Reveal the controls and (throttled) restart the auto-hide countdown.
  void _onPointerActivity() {
    widget.showControls.value = true;
    _controlsThrottle.run(_startHideControlsTimer);
  }

  /// The fullscreen media-library affordance, anchored to the right edge.
  ///
  /// It lives inside this widget (and therefore inside the video's
  /// [MouseRegion]) on purpose: as a sibling above the video, crossing onto it
  /// fired the region's `onExit`, which hid the controls — and the button with
  /// them — before a click could land.
  Widget _buildMediaLibraryButton(bool visible) {
    return Positioned(
      top: 0,
      bottom: 0,
      right: 12.0,
      child: Center(
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !visible,
            child: Tooltip(
              message: 'Media Library',
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onOpenMediaLibrary,
                  child: const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Icon(
                      Icons.video_library,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Tap toggles the controls — the touch equivalent of hover, since a tap
  /// produces no hover/move event to reveal them.
  void _onToggleControls() {
    if (widget.showControls.value) {
      _hideControlsTimer?.cancel();
      widget.showControls.value = false;
    } else {
      _onPointerActivity();
    }
  }

  /// Width the video actually occupies, so the funscript graph can be bounded
  /// to it rather than the whole area when the video is pillarboxed.
  double _computeDisplayWidth(
    BoxConstraints constraints,
    int? videoWidth,
    int? videoHeight,
  ) {
    if (videoWidth != null &&
        videoHeight != null &&
        videoWidth > 0 &&
        videoHeight > 0) {
      final screenAspect = constraints.maxWidth / constraints.maxHeight;
      final videoAspect = videoWidth / videoHeight;
      if (videoAspect < screenAspect) {
        return constraints.maxHeight * videoAspect;
      }
    }
    return constraints.maxWidth;
  }

  Widget _buildOverlayColumn(
    BuildContext context,
    VideoPlayer player,
    ActivePlaybackSession activeSession,
    PlayerModel playerModel,
    SettingsModel settings, {
    required bool showSettings,
    required bool showControls,
    required double displayWidth,
  }) {
    return Column(
      children: [
        Expanded(
          flex: 10,
          child: SettingsOverlay(
            showSettings: showSettings,
            child: ScriptPlayerSettings(),
          ),
        ),
        // A SignalBuilder rather than a plain read: this column is built from
        // inside a LayoutBuilder callback, which runs during layout rather than
        // during this element's build, so implicit tracking would not see it.
        SignalBuilder(
          builder: (context) => widget.showFunscriptGraph.value
              ? ConstrainedBox(
                  // Height is a single clamped value rather than a
                  // fixed-fraction SizedBox fighting a min/max ConstrainedBox;
                  // width stays bounded to the (possibly pillarboxed) video.
                  constraints: BoxConstraints(maxWidth: displayWidth),
                  child: SizedBox(
                    height: (MediaQuery.sizeOf(context).height * 0.15).clamp(
                      50.0,
                      150.0,
                    ),
                    child: _funscriptGraph(
                      playerModel.currentlyOpen,
                      // The graph scrolls on the clock that is actually
                      // running, which under an external session is not the
                      // local player's.
                      activeSession.session.value,
                      settings,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        AnimatedOpacity(
          opacity: showControls ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !showControls,
            child: VideoControls(
              showFunscriptGraph: widget.showFunscriptGraph,
              showSettings: widget.showSettings,
              onFullscreenToggle: () =>
                  _onFullscreenToggle(context, player, settings),
            ),
          ),
        ),
      ],
    );
  }

  void _onFullscreenToggle(
    BuildContext context,
    VideoPlayer player,
    SettingsModel settings,
  ) {
    if (widget.isFullscreen) {
      // The fullscreen page owns the exit guard; fall back to a plain pop only
      // if it did not supply one.
      if (widget.onRequestExitFullscreen != null) {
        widget.onRequestExitFullscreen!();
      } else {
        Navigator.pop(context);
      }
    } else {
      if (_fullscreenRouteOpen) return;
      _fullscreenRouteOpen = true;
      // If the app is already fullscreen (global toggle), this route does not
      // own the window state; leaving it must keep the window fullscreen.
      final alreadyFullscreen = fullscreenController.isFullscreen.peek();
      if (!alreadyFullscreen) {
        unawaited(fullscreenController.enter());
      }
      final route = Navigator.push<void>(
        context,
        PageRouteBuilder<void>(
          // No cross-fade. The fullscreen page is opaque and covers the player
          // page in the same frame, while a fade paints both pages at once —
          // both draw the same captured texture laid out at different sizes,
          // which is the ghost frame that showed up on every toggle. The
          // route's own transition is also zero so the page cannot be semi-
          // transparent for a frame.
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              FullscreenVideoPage(
                player: player,
                isEmbeddedPlayerEnabled: settings.embeddedVideoPlayer.value,
                showControls: widget.showControls,
                showFunscriptGraph: widget.showFunscriptGraph,
                showSettings: widget.showSettings,
                ownsNativeFullscreen: !alreadyFullscreen,
              ),
        ),
      );
      unawaited(route.whenComplete(() => _fullscreenRouteOpen = false));
    }
  }

  Widget _funscriptGraph(
    ReadonlySignal<MediaFunscript?> currentlyOpen,
    PlaybackSession session,
    SettingsModel settings,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8.0, 0.0, 8.0, 0.0),
      decoration: stdBoxShadow(),
      child: ScrollingGraph(
        currentlyOpen: currentlyOpen,
        videoPosition: session.smoothPosition,
        viewDuration: settings.funscriptGraphViewDuration,
        playbackRate: session.playbackSpeed,
        strokeRange: settings.minMaxRange,
      ),
    );
  }

  Widget _videoContainer(Widget surface, int? videoWidth, int? videoHeight) {
    return Stack(
      children: [
        Center(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24.0),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlphaF(0.5),
                  spreadRadius: 5,
                  blurRadius: 7,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: videoWidth != null && videoHeight != null
                ? AspectRatio(
                    aspectRatio: videoWidth / videoHeight,
                    child: surface,
                  )
                : surface,
          ),
        ),
      ],
    );
  }
}
