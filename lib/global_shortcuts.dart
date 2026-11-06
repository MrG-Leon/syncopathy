import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/fullscreen_controller.dart';
import 'package:syncopathy/model/player_model.dart';
import 'package:syncopathy/model/settings_model.dart';
import 'package:syncopathy/model/shortcut_settings.dart';
import 'package:syncopathy/player/playback_session.dart';
import 'package:syncopathy/player/video_player.dart';
import 'package:syncopathy/widgets/shortcut_rebind_dialog.dart';

class TogglePauseIntent extends Intent {
  const TogglePauseIntent();
}

class NextTrackIntent extends Intent {
  const NextTrackIntent();
}

class PreviousTrackIntent extends Intent {
  const PreviousTrackIntent();
}

class ToggleHomeModeIntent extends Intent {
  const ToggleHomeModeIntent({this.edgeMode = false});
  final bool edgeMode;
}

class ToggleHomeModeHighIntent extends Intent {
  const ToggleHomeModeHighIntent();
}

class ReplaceScriptIntent extends Intent {
  const ReplaceScriptIntent();
}

class ToggleFullscreenIntent extends Intent {
  const ToggleFullscreenIntent();
}

class GlobalShortcutManager extends ShortcutManager {
  bool _isTextInputFocused() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final context = focus.context;
    if (context == null) return false;

    bool isEditable = false;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        isEditable = true;
        return false;
      }
      return true;
    });
    if (isEditable) return true;

    return context.findRenderObject() is RenderEditable;
  }

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (_isTextInputFocused()) {
      return KeyEventResult.ignored;
    }
    return super.handleKeypress(context, event);
  }
}

class GlobalShortcuts extends StatefulWidget {
  final Widget child;
  const GlobalShortcuts({super.key, required this.child});

  @override
  State<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends State<GlobalShortcuts> {
  // Reused across rebuilds; only its `shortcuts` map is reassigned when the
  // custom bindings change, instead of allocating a new manager each build.
  final GlobalShortcutManager _shortcutManager = GlobalShortcutManager();

  @override
  void dispose() {
    _shortcutManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final videoPlayer = context.read<VideoPlayer>();
    final activeSession = context.read<ActivePlaybackSession>();
    final settingsModel = context.read<SettingsModel>();
    final playerModel = context.read<PlayerModel>();

    return SignalBuilder(
      builder: (context) {
        final customShortcuts = settingsModel.customShortcuts.value;

        ShortcutActivator getActivator(AppShortcut shortcut) {
          return (customShortcuts[shortcut.id] ?? shortcut.defaultBinding)
              .toActivator();
        }

        // Keyboard bindings only — mouse-button bindings are handled by the
        // root Listener below (keyboard shortcuts never see pointer events).
        bool isKeyboardBinding(ShortcutBinding b) => b.mouseButton == null;

        _shortcutManager.shortcuts = <ShortcutActivator, Intent>{
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.togglePause.id] ??
                ShortcutDefinitions.togglePause.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.togglePause):
                const TogglePauseIntent(),
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.nextTrack.id] ??
                ShortcutDefinitions.nextTrack.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.nextTrack):
                const NextTrackIntent(),
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.previousTrack.id] ??
                ShortcutDefinitions.previousTrack.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.previousTrack):
                const PreviousTrackIntent(),
          // The user-configurable Home Mode shortcut toggles without scheduling
          // the auto-toggle; the Edge Mode shortcut (below) does.
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.toggleHomeMode.id] ??
                ShortcutDefinitions.toggleHomeMode.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.toggleHomeMode):
                const ToggleHomeModeIntent(edgeMode: false),
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.toggleHomeModeHigh.id] ??
                ShortcutDefinitions.toggleHomeModeHigh.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.toggleHomeModeHigh):
                const ToggleHomeModeHighIntent(),
          // Edge Mode: configurable shortcut that schedules an automatic
          // toggle-back after the configured delay. Listed at the end so if the
          // user configures the same key for multiple shortcuts the last one wins.
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.toggleEdgeMode.id] ??
                ShortcutDefinitions.toggleEdgeMode.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.toggleEdgeMode):
                const ToggleHomeModeIntent(edgeMode: true),
          // C is a reserved fixed binding: it toggles Home Mode and parks at
          // the top of the stroke (high). No Edge Mode auto-toggle.
          SingleActivator(LogicalKeyboardKey.keyC):
              const ToggleHomeModeHighIntent(),
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.replaceScript.id] ??
                ShortcutDefinitions.replaceScript.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.replaceScript):
                const ReplaceScriptIntent(),
          if (isKeyboardBinding(
            customShortcuts[ShortcutDefinitions.toggleFullscreen.id] ??
                ShortcutDefinitions.toggleFullscreen.defaultBinding,
          ))
            getActivator(ShortcutDefinitions.toggleFullscreen):
                const ToggleFullscreenIntent(),
        };

        // Mouse-button bindings for the root Listener. Keyed by the full
        // binding (button + modifiers) so Ctrl+Mouse Back and a bare Mouse
        // Back can coexist; later entries overwrite earlier ones, mirroring
        // the keyboard map's "last one wins" rule.
        final mouseBindings = <ShortcutBinding, Intent>{};
        void addMouseBinding(AppShortcut shortcut, Intent intent) {
          final binding =
              customShortcuts[shortcut.id] ?? shortcut.defaultBinding;
          if (binding.mouseButton != null) {
            mouseBindings[binding] = intent;
          }
        }

        addMouseBinding(
          ShortcutDefinitions.togglePause,
          const TogglePauseIntent(),
        );
        addMouseBinding(ShortcutDefinitions.nextTrack, const NextTrackIntent());
        addMouseBinding(
          ShortcutDefinitions.previousTrack,
          const PreviousTrackIntent(),
        );
        addMouseBinding(
          ShortcutDefinitions.toggleHomeMode,
          const ToggleHomeModeIntent(edgeMode: false),
        );
        addMouseBinding(
          ShortcutDefinitions.toggleHomeModeHigh,
          const ToggleHomeModeHighIntent(),
        );
        addMouseBinding(
          ShortcutDefinitions.toggleEdgeMode,
          const ToggleHomeModeIntent(edgeMode: true),
        );
        addMouseBinding(
          ShortcutDefinitions.replaceScript,
          const ReplaceScriptIntent(),
        );
        addMouseBinding(
          ShortcutDefinitions.toggleFullscreen,
          const ToggleFullscreenIntent(),
        );

        return Shortcuts.manager(
          manager: _shortcutManager,
          child: Actions(
            actions: <Type, Action<Intent>>{
              // Aimed at whichever session owns playback, not at the local
              // player: with HereSphere in charge, the pause key was stopping
              // an idle mpv while the headset carried on.
              TogglePauseIntent: CallbackAction<TogglePauseIntent>(
                onInvoke: (intent) {
                  final session = activeSession.value;
                  if (!session.supports(PlaybackCapability.playPause)) {
                    return null;
                  }
                  session.togglePause();
                  return null;
                },
              ),
              // Playlists are a local-player idea, so these stay local — but
              // only while the local player is the one playing. Skipping a
              // hidden playlist under an external session is a silent surprise.
              NextTrackIntent: CallbackAction<NextTrackIntent>(
                onInvoke: (intent) => videoPlayer.ownsPlayback
                    ? videoPlayer.jumpNextPlaylistEntry()
                    : null,
              ),
              PreviousTrackIntent: CallbackAction<PreviousTrackIntent>(
                onInvoke: (intent) => videoPlayer.ownsPlayback
                    ? videoPlayer.jumpPreviousPlaylistEntry()
                    : null,
              ),
              ToggleHomeModeIntent: CallbackAction<ToggleHomeModeIntent>(
                onInvoke: (intent) {
                  settingsModel.toggleHomeDevice(edgeMode: intent.edgeMode);
                  return null;
                },
              ),
              ToggleHomeModeHighIntent:
                  CallbackAction<ToggleHomeModeHighIntent>(
                    onInvoke: (intent) {
                      settingsModel.toggleHomeModeHigh();
                      return null;
                    },
                  ),
              ReplaceScriptIntent: CallbackAction<ReplaceScriptIntent>(
                onInvoke: (intent) {
                  final path = settingsModel.replaceScriptPath.value;
                  if (playerModel.isReplacementActive) {
                    playerModel.revertToOriginalScript();
                  } else if (path != null && path.isNotEmpty) {
                    playerModel.loadReplacementScript(path);
                  }
                  return null;
                },
              ),
              ToggleFullscreenIntent: CallbackAction<ToggleFullscreenIntent>(
                onInvoke: (intent) {
                  fullscreenController.toggle();
                  return null;
                },
              ),
            },
            child: Builder(
              // The pointer handler must invoke Actions with a context BELOW
              // the Actions widget: Actions.maybeInvoke only searches upward.
              // The State's context sits above Actions, so a raw Listener
              // here (using this.context) would silently no-op.
              builder: (listenerContext) => Listener(
                onPointerDown: _mouseShortcutHandler(
                  listenerContext,
                  mouseBindings,
                ),
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Builds a pointer listener that fires mouse-button shortcut bindings.
  /// The `Shortcuts`/`ShortcutManager` machinery only processes keyboard
  /// events, so bound middle/side buttons are dispatched here instead —
  /// into the same `Actions` map via [Actions.maybeInvoke]. [invokeContext]
  /// MUST be a context below the `Actions` widget.
  PointerDownEventListener _mouseShortcutHandler(
    BuildContext invokeContext,
    Map<ShortcutBinding, Intent> bindings,
  ) {
    return (event) {
      // A rebind dialog is capturing mouse buttons; don't fire the shortcut
      // being rebound underneath it.
      if (ShortcutRebindDialog.isCapturing) return;

      final String? button;
      final b = event.buttons;
      if (b & kMiddleMouseButton != 0) {
        button = MouseButtons.middle;
      } else if (b & kBackMouseButton != 0) {
        button = MouseButtons.back;
      } else if (b & kForwardMouseButton != 0) {
        button = MouseButtons.forward;
      } else {
        return; // primary/secondary clicks belong to normal UI interaction
      }

      // Exact match on button + modifiers, same semantics as SingleActivator.
      final hk = HardwareKeyboard.instance;
      final pressed = ShortcutBinding.mouse(
        button,
        control: hk.isControlPressed,
        shift: hk.isShiftPressed,
        alt: hk.isAltPressed,
        meta: hk.isMetaPressed,
      );
      final intent = bindings[pressed];
      if (intent == null) return;
      Actions.maybeInvoke(invokeContext, intent);
    };
  }
}
