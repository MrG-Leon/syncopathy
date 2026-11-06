import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/logging.dart';
import 'package:syncopathy/simple/simple_mode/simple_mode.dart';

/// Application-wide fullscreen state.
///
/// Every fullscreen entry point routes through this controller: the app-bar
/// button, the configurable shortcut, and the video player's fullscreen page.
/// A single flag keeps the native window (desktop/web) and the mobile system
/// bars from disagreeing about whether the app is fullscreen.
class FullscreenController {
  final Signal<bool> isFullscreen = signal(false);

  bool get value => isFullscreen.peek();

  Future<void> toggle() => isFullscreen.peek() ? exit() : enter();

  Future<void> enter() async {
    if (isFullscreen.peek()) return;
    // The signal flips immediately so callers (e.g. the video player route)
    // see a consistent state while the native transition is still running.
    isFullscreen.value = true;
    await _applySystemUi(true);
    if (kIsWeb || _isDesktop) {
      await _applyNativeFullscreen(true);
    }
  }

  Future<void> exit() async {
    if (!isFullscreen.peek()) return;
    isFullscreen.value = false;
    await _applySystemUi(false);
    if (kIsWeb || _isDesktop) {
      await _applyNativeFullscreen(false);
    }
  }

  /// Restores the mobile system bars without changing the fullscreen flag.
  /// Used when the owning page is torn down and fullscreen is already off.
  Future<void> restoreSystemUi() async {
    if (isFullscreen.peek()) return;
    await _applySystemUi(false);
  }

  /// Keeps the flag truthful when the window manager changes fullscreen state
  /// without going through this controller (OS window menu, external shortcut,
  /// or a refused transition). Desktop-only: the caller is the native window
  /// listener, which only exists where a native window does.
  void syncFromNativeWindow(bool fullscreen) {
    if (isFullscreen.peek() == fullscreen) return;
    isFullscreen.value = fullscreen;
  }

  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> _applyNativeFullscreen(bool enabled) async {
    try {
      await (enabled
          ? SimpleMode.enterFullscreen()
          : SimpleMode.exitFullscreen());
    } catch (error) {
      // A window manager / browser can refuse a fullscreen request (for
      // example a web page entered from a non-gesture event). The Flutter UI
      // still switches modes, so this is logged rather than surfaced.
      Logger.warning('Fullscreen transition failed: $error');
    }
  }

  Future<void> _applySystemUi(bool fullscreen) async {
    if (kIsWeb) return;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS has no immersive modes: hide the status bar by emptying the
        // manual overlay set, and restore both overlays on exit.
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: fullscreen ? const [] : SystemUiOverlay.values,
        );
      }
    } catch (error) {
      Logger.warning('System UI mode change failed: $error');
    }
  }
}

/// The single instance shared by the app bar, the shortcut handler and the
/// fullscreen video page.
final FullscreenController fullscreenController = FullscreenController();
