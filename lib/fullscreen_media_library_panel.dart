import 'dart:math';

import 'package:flutter/material.dart';
import 'package:syncopathy/media_library/media_library.dart';

/// Slide-over media library shown on top of the video player's fullscreen
/// page.
///
/// It hosts the very same [MediaLibrary] widget the Media tab uses, so every
/// existing feature (search, sorting, filters, view options, categories,
/// selection, random picker, playlist, matching, detail page, rating,
/// deletion, moving files) stays available. The refresh control is the one
/// deliberate exclusion, and the toolbar switches to its compact wrapping
/// layout because a panel is much narrower than the Media tab.
class FullscreenMediaLibraryPanel extends StatelessWidget {
  final VoidCallback onClose;

  const FullscreenMediaLibraryPanel({super.key, required this.onClose});

  static const double _minPanelWidth = 420.0;
  static const double _maxPanelWidth = 820.0;

  /// Minimum width a grid card needs before another column is added, so the
  /// configured "videos per row" does not squeeze cards into unreadable slivers
  /// in a narrow panel.
  static const double _minCardWidth = 190.0;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final panelWidth = screenSize.width >= 900
        ? (screenSize.width * 0.46).clamp(_minPanelWidth, _maxPanelWidth)
        : screenSize.width;
    final maxColumns = max(1, min(4, (panelWidth / _minCardWidth).floor()));

    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        // Modal barrier: taps on the video close the panel instead of
        // reaching the controls underneath.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: Colors.black54),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TweenAnimationBuilder<Offset>(
            tween: Tween(begin: const Offset(1.0, 0.0), end: Offset.zero),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, offset, child) =>
                FractionalTranslation(translation: offset, child: child),
            child: SizedBox(
              width: panelWidth,
              height: screenSize.height,
              child: Material(
                color: scheme.surface,
                elevation: 16,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: SafeArea(
                    left: false,
                    child: Column(
                      children: [
                        _buildHeader(context),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                            child: MediaLibrary(
                              compact: true,
                              showRefresh: false,
                              isActive: true,
                              maxVideosPerRow: maxColumns,
                              // Picker semantics: once a video (or playlist)
                              // starts playing, get out of the way so the video
                              // is visible.
                              onMediaOpen: onClose,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // Swipe the header to the right to close, mirroring the right-edge swipe
      // that opens the panel.
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0.0;
        if (velocity > 250.0) onClose();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16.0, 12.0, 8.0, 8.0),
        child: Row(
          children: [
            Icon(Icons.video_library, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Media Library',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close media library',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
