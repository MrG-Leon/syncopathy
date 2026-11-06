import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncopathy/ioc.dart';
import 'package:syncopathy/model/auto_home.dart';
import 'package:syncopathy/model/home_target.dart';
import 'package:syncopathy/model/json/settings.dart';
import 'package:syncopathy/model/settings_model.dart';
import 'package:syncopathy/platform/key_value_store/key_value_store.dart';

class _FakeKeyValueStore implements IKeyValueStore {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<Map<String, dynamic>?> get(String key) async => values[key];

  @override
  Future<void> put(String key, Map<String, dynamic> json) async {
    values[key] = json;
  }
}

/// Covers "Home on pause": the ownership rules that decide when playback state
/// may drive Home Mode, plus the two settings behind the feature.
void main() {
  group('AutoHomeController', () {
    late AutoHomeController controller;
    var homeEnabled = false;

    /// Feeds one state change through the controller and applies its answer,
    /// mirroring what the effect in PlayerModel does.
    void update({bool autoHomeOnPause = true, required bool paused}) {
      final next = controller.nextHomeState(
        autoHomeOnPause: autoHomeOnPause,
        paused: paused,
        homeEnabled: homeEnabled,
      );
      if (next != null) homeEnabled = next;
    }

    /// The user reaching for the home button or its shortcut. The effect
    /// tracks the flag, so the controller sees the change on the next run.
    void userToggles({bool autoHomeOnPause = true, required bool paused}) {
      homeEnabled = !homeEnabled;
      update(autoHomeOnPause: autoHomeOnPause, paused: paused);
    }

    setUp(() {
      controller = AutoHomeController();
      homeEnabled = false;
      // The first evaluation only establishes a baseline; start from playing
      // so the tests below describe transitions rather than startup.
      update(paused: false);
    });

    test('leaves Home Mode alone while the setting is off', () {
      update(autoHomeOnPause: false, paused: true);
      expect(homeEnabled, isFalse);
      expect(controller.engaged.value, isFalse);
    });

    test('parks on pause and releases on resume', () {
      update(paused: true);
      expect(homeEnabled, isTrue);
      expect(controller.engaged.value, isTrue);

      update(paused: false);
      expect(homeEnabled, isFalse);
      expect(controller.engaged.value, isFalse);
    });

    test('parks again on the next pause', () {
      update(paused: true);
      update(paused: false);
      update(paused: true);
      expect(homeEnabled, isTrue);
      expect(controller.engaged.value, isTrue);
    });

    test('does not seize the device on the first evaluation', () {
      final fresh = AutoHomeController();
      expect(
        fresh.nextHomeState(
          autoHomeOnPause: true,
          paused: true,
          homeEnabled: false,
        ),
        isNull,
      );
      expect(fresh.engaged.value, isFalse);
    });

    test('parks when the setting is switched on during a pause', () {
      update(autoHomeOnPause: false, paused: true);
      expect(homeEnabled, isFalse);

      update(paused: true);
      expect(homeEnabled, isTrue);
      expect(controller.engaged.value, isTrue);
    });

    test('does not claim a park the user made themselves', () {
      userToggles(paused: false);
      expect(homeEnabled, isTrue);
      expect(controller.engaged.value, isFalse);

      update(paused: true);
      expect(controller.engaged.value, isFalse);

      // Resuming must not undo what the user switched on by hand.
      update(paused: false);
      expect(homeEnabled, isTrue);
    });

    test('keeps a park the user switched on again mid-pause', () {
      update(paused: true);
      expect(controller.engaged.value, isTrue);

      // Off, then on again: the second tap makes the park theirs.
      userToggles(paused: true);
      expect(homeEnabled, isFalse);
      userToggles(paused: true);
      expect(homeEnabled, isTrue);
      expect(controller.engaged.value, isFalse);

      update(paused: false);
      expect(homeEnabled, isTrue);
    });

    test('does not re-park after the user releases it mid-pause', () {
      update(paused: true);
      userToggles(paused: true);
      expect(homeEnabled, isFalse);

      // Nothing else changed, so the release stands.
      update(paused: true);
      expect(homeEnabled, isFalse);
      expect(controller.engaged.value, isFalse);
    });

    test('releases its own park when the setting is switched off', () {
      update(paused: true);
      update(autoHomeOnPause: false, paused: true);
      expect(homeEnabled, isFalse);
      expect(controller.engaged.value, isFalse);
    });

    test('leaves a manual park in place when the setting is switched off', () {
      userToggles(paused: false);
      update(paused: true);
      update(autoHomeOnPause: false, paused: true);
      expect(homeEnabled, isTrue);
    });

    test('re-parking is idempotent while paused', () {
      update(paused: true);
      expect(
        controller.nextHomeState(
          autoHomeOnPause: true,
          paused: true,
          homeEnabled: true,
        ),
        isNull,
      );
      expect(controller.engaged.value, isTrue);
    });
  });

  group('autoHomeOnPause setting', () {
    test('is off by default', () {
      expect(Settings().autoHomeOnPause, isFalse);
      expect(SettingsModel().autoHomeOnPause.value, isFalse);
    });

    test('round-trips through json', () {
      final json = (Settings()..autoHomeOnPause = true).toJson();
      expect(Settings.fromJson(json).autoHomeOnPause, isTrue);
    });

    test('falls back to off when the stored value is missing', () {
      final json = Settings().toJson()..remove('autoHomeOnPause');
      expect(Settings.fromJson(json).autoHomeOnPause, isFalse);
    });
  });

  group('homeMoveDurationMs setting', () {
    test('defaults to the shared park duration', () {
      expect(Settings().homeMoveDurationMs, HomeTarget.defaultMoveDurationMs);
      expect(
        SettingsModel().homeMoveDurationMs.value,
        HomeTarget.defaultMoveDurationMs,
      );
    });

    test('round-trips through json', () {
      final json = (Settings()..homeMoveDurationMs = 1500).toJson();
      expect(Settings.fromJson(json).homeMoveDurationMs, 1500);
    });

    test('falls back to the default when the stored value is missing', () {
      final json = Settings().toJson()..remove('homeMoveDurationMs');
      expect(
        Settings.fromJson(json).homeMoveDurationMs,
        HomeTarget.defaultMoveDurationMs,
      );
    });

    test('the default sits inside the configurable range', () {
      expect(
        HomeTarget.defaultMoveDurationMs,
        inInclusiveRange(
          HomeTarget.minMoveDurationMs,
          HomeTarget.maxMoveDurationMs,
        ),
      );
    });
  });

  group('edgeModeActivationCount', () {
    test('counts Edge Mode entries for this session only', () async {
      final settings = SettingsModel();
      expect(settings.edgeModeActivationCount.value, 0);

      settings.toggleHomeDevice(edgeMode: true);
      expect(settings.edgeModeActivationCount.value, 1);

      // Toggling Edge Mode off again is not another entry.
      settings.toggleHomeDevice(edgeMode: true);
      expect(settings.edgeModeActivationCount.value, 1);

      settings.toggleHomeDevice(edgeMode: true);
      expect(settings.edgeModeActivationCount.value, 2);

      await settings.dispose();

      // A fresh model represents a fresh session.
      expect(SettingsModel().edgeModeActivationCount.value, 0);
    });
  });

  group('edge mode adjustments', () {
    test('automatic toggle-back reduces intensity and increases the next delay', () {
      fakeAsync((async) {
        final settings = SettingsModel()
          ..intensity.value = 1.0
          ..edgeModeIntensityStep.value = 0.05
          ..edgeModeAutoToggleDelaySeconds.value = 10
          ..edgeModeDelayStepSeconds.value = 4;

        settings.toggleHomeDevice(edgeMode: true);
        expect(settings.homeDeviceEnabled.value, isTrue);

        async.elapse(const Duration(seconds: 10));

        expect(settings.homeDeviceEnabled.value, isFalse);
        expect(settings.intensity.value, closeTo(0.95, 1e-9));
        expect(settings.edgeModeAutoToggleDelaySeconds.value, 14);
      });
    });

    test('manual exit leaves intensity and the next delay unchanged', () {
      fakeAsync((async) {
        final settings = SettingsModel()
          ..intensity.value = 1.0
          ..edgeModeIntensityStep.value = 0.05
          ..edgeModeAutoToggleDelaySeconds.value = 10
          ..edgeModeDelayStepSeconds.value = 4;

        settings.toggleHomeDevice(edgeMode: true);
        settings.toggleHomeDevice(edgeMode: true); // manual exit

        async.elapse(const Duration(seconds: 10));

        expect(settings.homeDeviceEnabled.value, isFalse);
        expect(settings.intensity.value, 1.0);
        expect(settings.edgeModeAutoToggleDelaySeconds.value, 10);
      });
    });

    test('adjustment settings round-trip through json', () {
      final json = (Settings()
            ..edgeModeIntensityStep = 0.12
            ..edgeModeDelayStepSeconds = 7
            ..edgeModeIntensityFloor = 0.2
            ..edgeModeDelayCeilingSeconds = 60)
          .toJson();
      final decoded = Settings.fromJson(json);
      expect(decoded.edgeModeIntensityStep, 0.12);
      expect(decoded.edgeModeDelayStepSeconds, 7);
      expect(decoded.edgeModeIntensityFloor, 0.2);
      expect(decoded.edgeModeDelayCeilingSeconds, 60);
    });

    test('automatic adjustments stop at the configured bounds', () {
      fakeAsync((async) {
        final settings = SettingsModel()
          ..intensity.value = 0.07
          ..edgeModeIntensityStep.value = 0.05
          ..edgeModeIntensityFloor.value = 0.05
          ..edgeModeAutoToggleDelaySeconds.value = 88
          ..edgeModeDelayStepSeconds.value = 5
          ..edgeModeDelayCeilingSeconds.value = 90;

        settings.toggleHomeDevice(edgeMode: true);
        async.elapse(const Duration(seconds: 88));

        expect(settings.intensity.value, closeTo(0.05, 1e-9));
        expect(settings.edgeModeAutoToggleDelaySeconds.value, 90);

        // At both bounds the next automatic toggle-back changes nothing.
        settings.toggleHomeDevice(edgeMode: true);
        async.elapse(const Duration(seconds: 90));

        expect(settings.intensity.value, closeTo(0.05, 1e-9));
        expect(settings.edgeModeAutoToggleDelaySeconds.value, 90);
      });
    });
  });

  group('edge mode persistence', () {
    late _FakeKeyValueStore store;

    setUp(() async {
      await getIt.reset();
      store = _FakeKeyValueStore();
      getIt.registerSingleton<IKeyValueStore>(store);
    });

    tearDown(() async {
      await getIt.reset();
    });

    test('automatic adjustments stay session-local while manual changes persist', () {
      fakeAsync((async) {
        store.values[Settings.key] = (Settings()
              ..intensity = 1.0
              ..edgeModeAutoToggleDelaySeconds = 20)
            .toJson();

        final settings = SettingsModel();
        unawaited(settings.load());
        async.flushMicrotasks();

        expect(settings.intensity.value, 1.0);
        expect(settings.edgeModeAutoToggleDelaySeconds.value, 20);

        // Manual changes are written to the persisted entity.
        settings.setIntensity(1.5);
        settings.setEdgeModeDelay(12);
        async.elapse(const Duration(milliseconds: 600));
        expect(store.values[Settings.key]!['intensity'], 1.5);
        expect(
          store.values[Settings.key]!['edgeModeAutoToggleDelaySeconds'],
          12,
        );

        // A save triggered by another bound setting still writes the manual
        // values, not anything Edge Mode changes later.
        settings.edgeModeIntensityStep.value = 0.05;
        settings.edgeModeDelayStepSeconds.value = 4;
        async.elapse(const Duration(milliseconds: 600));
        expect(store.values[Settings.key]!['intensity'], 1.5);
        expect(
          store.values[Settings.key]!['edgeModeAutoToggleDelaySeconds'],
          12,
        );

        // The automatic toggle-back changes only the live signals.
        settings.toggleHomeDevice(edgeMode: true);
        async.elapse(const Duration(seconds: 12));
        expect(settings.intensity.value, closeTo(1.45, 1e-9));
        expect(settings.edgeModeAutoToggleDelaySeconds.value, 16);
        expect(store.values[Settings.key]!['intensity'], 1.5);
        expect(
          store.values[Settings.key]!['edgeModeAutoToggleDelaySeconds'],
          12,
        );

        // A save triggered after the automatic adjustment still writes the
        // manual values.
        settings.edgeModeIntensityStep.value = 0.06;
        async.elapse(const Duration(milliseconds: 600));
        expect(store.values[Settings.key]!['intensity'], 1.5);
        expect(
          store.values[Settings.key]!['edgeModeAutoToggleDelaySeconds'],
          12,
        );

        // A restart returns to the manually persisted values.
        final restarted = SettingsModel();
        unawaited(restarted.load());
        async.flushMicrotasks();
        expect(restarted.intensity.value, 1.5);
        expect(restarted.edgeModeAutoToggleDelaySeconds.value, 12);

        unawaited(settings.dispose());
        unawaited(restarted.dispose());
      });
    });
  });
}
