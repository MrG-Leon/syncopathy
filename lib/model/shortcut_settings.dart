import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:json_annotation/json_annotation.dart';

part 'shortcut_settings.g.dart';

/// Mouse buttons that can be bound as shortcut triggers (in addition to
/// keyboard keys). Stored as strings in [ShortcutBinding.mouseButton].
class MouseButtons {
  static const middle = 'middle';
  static const back = 'back';
  static const forward = 'forward';

  static const all = [middle, back, forward];

  static String label(String button) => switch (button) {
    middle => 'Mouse Middle',
    back => 'Mouse Back (XButton1)',
    forward => 'Mouse Forward (XButton2)',
    _ => button,
  };
}

@JsonSerializable()
class ShortcutBinding {
  final int keyId;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  /// Non-null when this binding is a mouse button ([MouseButtons.all]) rather
  /// than a keyboard key. [keyId] is unused in that case (kept as 0).
  final String? mouseButton;

  ShortcutBinding({
    required this.keyId,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    this.mouseButton,
  });

  /// Builds a mouse-button binding, carrying the currently held keyboard
  /// modifiers so combinations like Ctrl+Mouse Back work.
  factory ShortcutBinding.mouse(
    String button, {
    bool control = false,
    bool shift = false,
    bool alt = false,
    bool meta = false,
  }) {
    return ShortcutBinding(
      keyId: 0,
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
      mouseButton: button,
    );
  }

  factory ShortcutBinding.fromActivator(SingleActivator activator) {
    return ShortcutBinding(
      keyId: activator.trigger.keyId,
      control: activator.control,
      shift: activator.shift,
      alt: activator.alt,
      meta: activator.meta,
    );
  }

  SingleActivator toActivator() {
    return SingleActivator(
      LogicalKeyboardKey(keyId),
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
    );
  }

  factory ShortcutBinding.fromJson(Map<String, dynamic> json) =>
      _$ShortcutBindingFromJson(json);

  Map<String, dynamic> toJson() => _$ShortcutBindingToJson(this);

  @override
  String toString() {
    final List<String> modifiers = [];
    if (control) modifiers.add('Ctrl');
    if (alt) modifiers.add('Alt');
    if (shift) modifiers.add('Shift');
    if (meta) modifiers.add('Meta');

    if (mouseButton != null) {
      modifiers.add(MouseButtons.label(mouseButton!));
      return modifiers.join(' + ');
    }

    final key = LogicalKeyboardKey(keyId);
    String label = key.keyLabel;
    if (key == LogicalKeyboardKey.space) {
      label = 'Space';
    } else if (label.trim().isEmpty) {
      label = key.debugName ?? 'Unknown';
    }

    modifiers.add(label);
    return modifiers.join(' + ');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShortcutBinding &&
          runtimeType == other.runtimeType &&
          keyId == other.keyId &&
          control == other.control &&
          shift == other.shift &&
          alt == other.alt &&
          meta == other.meta &&
          mouseButton == other.mouseButton;

  @override
  int get hashCode =>
      keyId.hashCode ^
      control.hashCode ^
      shift.hashCode ^
      alt.hashCode ^
      meta.hashCode ^
      mouseButton.hashCode;
}

class AppShortcut {
  final String id;
  final String name;
  final String description;
  final SingleActivator defaultActivator;

  const AppShortcut({
    required this.id,
    required this.name,
    required this.description,
    required this.defaultActivator,
  });

  ShortcutBinding get defaultBinding =>
      ShortcutBinding.fromActivator(defaultActivator);
}

class ShortcutDefinitions {
  static const togglePause = AppShortcut(
    id: 'togglePause',
    name: 'Toggle Play/Pause',
    description: 'Play or pause the video',
    defaultActivator: SingleActivator(LogicalKeyboardKey.space),
  );

  static const nextTrack = AppShortcut(
    id: 'nextTrack',
    name: 'Next Track',
    description: 'Play next track in playlist',
    defaultActivator: SingleActivator(LogicalKeyboardKey.keyN),
  );

  static const previousTrack = AppShortcut(
    id: 'previousTrack',
    name: 'Previous Track',
    description: 'Play previous track in playlist',
    defaultActivator: SingleActivator(LogicalKeyboardKey.keyP),
  );

  static const toggleHomeMode = AppShortcut(
    id: 'toggleHomeMode',
    name: 'Toggle Home Mode',
    description: 'Toggle Home Mode (Handy)',
    defaultActivator: SingleActivator(LogicalKeyboardKey.keyH),
  );

  static const toggleHomeModeHigh = AppShortcut(
    id: 'toggleHomeModeHigh',
    name: 'Toggle Home Mode (Park High)',
    description: 'Enter Home Mode and park at the top of the stroke (C)',
    defaultActivator: SingleActivator(LogicalKeyboardKey.keyC),
  );

  static const toggleEdgeMode = AppShortcut(
    id: 'toggleEdgeMode',
    name: 'Toggle Home Mode (Edge Mode)',
    description: 'Toggle Home Mode with auto-toggle after a delay',
    defaultActivator: SingleActivator(LogicalKeyboardKey.keyZ),
  );

  static const replaceScript = AppShortcut(
    id: 'replaceScript',
    name: 'Replace Script',
    description: 'Replace the current funscript with a configured one',
    defaultActivator: SingleActivator(LogicalKeyboardKey.f1),
  );

  static const toggleFullscreen = AppShortcut(
    id: 'toggleFullscreen',
    name: 'Toggle Fullscreen',
    description: 'Enter or leave the application-wide fullscreen mode',
    defaultActivator: SingleActivator(LogicalKeyboardKey.f11),
  );

  static List<AppShortcut> get all => [
    togglePause,
    nextTrack,
    previousTrack,
    toggleHomeMode,
    toggleHomeModeHigh,
    toggleEdgeMode,
    replaceScript,
    toggleFullscreen,
  ];
}
