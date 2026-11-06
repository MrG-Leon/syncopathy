import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncopathy/fullscreen_controller.dart';
import 'package:syncopathy/model/shortcut_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The system UI channel has no engine behind it in tests; answer it so
    // SystemChrome calls resolve instead of throwing.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('FullscreenController', () {
    testWidgets('enter, exit and toggle update the shared flag', (
      tester,
    ) async {
      final controller = FullscreenController();
      expect(controller.isFullscreen.value, isFalse);

      await controller.enter();
      expect(controller.isFullscreen.value, isTrue);

      await controller.toggle();
      expect(controller.isFullscreen.value, isFalse);

      await controller.toggle();
      expect(controller.isFullscreen.value, isTrue);

      await controller.exit();
      expect(controller.isFullscreen.value, isFalse);
    });

    testWidgets('repeated enter/exit are idempotent', (tester) async {
      final controller = FullscreenController();

      await controller.enter();
      await controller.enter();
      expect(controller.isFullscreen.value, isTrue);

      await controller.exit();
      await controller.exit();
      expect(controller.isFullscreen.value, isFalse);
    });

    test('native window changes are mirrored', () {
      final controller = FullscreenController();

      controller.syncFromNativeWindow(true);
      expect(controller.isFullscreen.value, isTrue);

      controller.syncFromNativeWindow(false);
      expect(controller.isFullscreen.value, isFalse);
    });
  });

  test('fullscreen is exposed as a configurable shortcut', () {
    const shortcut = ShortcutDefinitions.toggleFullscreen;
    expect(ShortcutDefinitions.all, contains(shortcut));
    expect(shortcut.defaultBinding.keyId, LogicalKeyboardKey.f11.keyId);
  });
}
