import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/fullscreen_controller.dart';
import 'package:syncopathy/fullscreen_media_library_panel.dart';
import 'package:syncopathy/ioc.dart';
import 'package:syncopathy/player/video_player.dart';
import 'package:syncopathy/video_widget.dart';

class FullscreenVideoPage extends StatefulWidget {
  final VideoPlayer player;
  final Signal<bool> showFunscriptGraph;
  final Signal<bool> showSettings;
  final Signal<bool> showControls;
  final bool isEmbeddedPlayerEnabled;

  /// Whether opening this page is what turned native fullscreen on. When the
  /// app was already fullscreen (the global toggle), leaving the video's
  /// fullscreen route must not drop the window back to windowed mode.
  final bool ownsNativeFullscreen;

  const FullscreenVideoPage({
    super.key,
    required this.player,
    required this.isEmbeddedPlayerEnabled,
    required this.showFunscriptGraph,
    required this.showSettings,
    required this.showControls,
    required this.ownsNativeFullscreen,
  });

  @override
  State<FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<FullscreenVideoPage> {
  bool _exiting = false;
  bool _showLibrary = false;

  // Right-edge swipe tracking: only drags that start near the right edge are
  // treated as "pull the media library out", so ordinary drags (volume slider,
  // funscript graph) keep their own gesture behaviour.
  static const double _swipeStartZone = 0.85;
  static const double _swipeOpenDistance = 60.0;
  static const double _swipeOpenVelocity = 300.0;

  double? _swipeStartX;
  double _swipeDx = 0.0;

  late final void Function() _fullscreenEffectDispose;

  @override
  void initState() {
    super.initState();
    _fullscreenEffectDispose = effect(() {
      // Fullscreen can also be turned off from outside this page — the app-bar
      // button before the route opened, or the global shortcut pressed while
      // this page is on top. Close the route so the video mode and the window
      // mode never disagree.
      if (!fullscreenController.isFullscreen.value) {
        _requestExit();
      }
    });
  }

  @override
  void dispose() {
    _fullscreenEffectDispose();
    super.dispose();
  }

  // Every exit routes through here so leaving fullscreen always restores the
  // OS/browser window. Popping the route directly (e.g. system back or a
  // predictive-back gesture) would otherwise strand the window fullscreen.
  // The native transition is started, not awaited: the route can begin its
  // exit immediately and the two animations run concurrently. Repeated
  // Escape/back/button events must not pop the route below this page.
  void _requestExit() {
    if (_exiting) return;
    _exiting = true;
    if (widget.ownsNativeFullscreen) {
      unawaited(fullscreenController.exit());
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _setLibraryVisible(bool visible) {
    if (_showLibrary == visible) return;
    setState(() => _showLibrary = visible);
  }

  void _toggleLibrary() => _setLibraryVisible(!_showLibrary);

  void _closeLibrary() => _setLibraryVisible(false);

  /// Back / Escape close the library first, and only exit fullscreen when the
  /// library is not open — mirrors how a drawer behaves over a page.
  void _handleBack() {
    if (_showLibrary) {
      _closeLibrary();
    } else {
      _requestExit();
    }
  }

  void _onSwipeStart(DragStartDetails details) {
    _swipeStartX = details.localPosition.dx;
    _swipeDx = 0.0;
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    _swipeDx += details.delta.dx;
  }

  void _onSwipeEnd(DragEndDetails details) {
    final startX = _swipeStartX;
    _swipeStartX = null;
    if (startX == null || _showLibrary || !mounted) return;

    final width = MediaQuery.sizeOf(context).width;
    final startedAtRightEdge = startX >= width * _swipeStartZone;
    final velocity = details.primaryVelocity ?? 0.0;
    final swipedLeft =
        _swipeDx <= -_swipeOpenDistance || velocity <= -_swipeOpenVelocity;
    if (startedAtRightEdge && swipedLeft) {
      _setLibraryVisible(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Focus(
        autofocus: true,
        // Escape is a keyboard exit even while the auto-hiding controls (and
        // their fullscreen toggle) are hidden. As an ancestor Focus it still
        // receives the key when a descendant control holds primary focus.
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _handleBack();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: widget.isEmbeddedPlayerEnabled
              ? Colors.black
              : Colors.transparent,
          // No Hero here: the video controls use OverlayPortal-backed
          // Tooltips, and a Hero flight reparents that subtree into the
          // Navigator overlay, tripping an overlay-theater assertion. A plain
          // route transition avoids the crash.
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  // Include the full page, not just the video surface: the
                  // opening swipe starts at the very screen edge, which can be
                  // letterboxing outside the video.
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: _onSwipeStart,
                  onHorizontalDragUpdate: _onSwipeUpdate,
                  onHorizontalDragEnd: _onSwipeEnd,
                  child: ExcludeFocus(
                    // While the modal library panel is up, keyboard focus must
                    // not reach the video controls behind it.
                    excluding: _showLibrary,
                    child: Center(
                      child: VideoWidget(
                        player: widget.player,
                        isFullscreen: true,
                        showControls: widget.showControls,
                        showFunscriptGraph: widget.showFunscriptGraph,
                        showSettings: widget.showSettings,
                        onRequestExitFullscreen: _requestExit,
                        // Simple mode has no media library (and no library
                        // providers), so the affordance is only wired for the
                        // library build.
                        onOpenMediaLibrary: syncopathySimpleMode
                            ? null
                            : _toggleLibrary,
                      ),
                    ),
                  ),
                ),
              ),
              // Simple mode has no media library (and no library providers), so
              // the affordance is only built for the library build.
              if (_showLibrary)
                FullscreenMediaLibraryPanel(onClose: _closeLibrary),
            ],
          ),
        ),
      ),
    );
  }
}
