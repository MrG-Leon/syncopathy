import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/fullscreen_controller.dart';
import 'package:syncopathy/helper/effect_dispose_mixin.dart';
import 'package:syncopathy/ioc.dart';
import 'package:syncopathy/model/player_model.dart';
import 'package:syncopathy/model/settings_model.dart';
import 'package:syncopathy/player/video_player.dart';
import 'package:syncopathy/video_widget.dart';

class VideoPlayerPage extends SignalStatefulWidget {
  const VideoPlayerPage({super.key});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with AutomaticKeepAliveClientMixin, EffectDispose {
  @override
  bool get wantKeepAlive => true;

  final Signal<bool> _showSettings = signal(false);
  final Signal<bool> _showControls = signal(true);

  @override
  void dispose() {
    effectDispose();
    _showSettings.dispose();
    _showControls.dispose();
    // Fire-and-forget: dispose() must stay synchronous, and awaiting across the
    // teardown gap risks the chrome reset being dropped. Only restores the
    // system bars when the app-wide fullscreen mode is not holding them
    // hidden.
    fullscreenController.restoreSystemUi();
    super.dispose();
  }

  Widget _overlayCard({required Key key, required List<Widget> children}) {
    return Center(
      key: key,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(24),
        ),
        padding: const EdgeInsets.all(24.0),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final player = context.read<VideoPlayer>();
    final playerModel = context.read<PlayerModel>();
    final settingsModel = context.read<SettingsModel>();
    final noFunscriptLoaded = playerModel.currentlyOpen.value == null;
    // Nothing open but a playlist is active → we're between entries (a brief
    // transition), which warrants a spinner rather than the idle empty state.
    final inPlaylistTransition =
        noFunscriptLoaded && player.currentPlaylist.value.entries.isNotEmpty;

    return Stack(
      children: [
        // No Hero: the controls' OverlayPortal-backed Tooltips can't survive a
        // Hero flight into the Navigator overlay (it asserts on the overlay
        // theater size). Fullscreen uses a plain route transition instead.
        VideoWidget(
          player: player,
          isFullscreen: false,
          showControls: _showControls,
          showFunscriptGraph: settingsModel.funscriptGraphEnabled,
          showSettings: _showSettings,
        ),
        AnimatedSwitcher(
          // Short enough not to hide a fast first frame behind the spinner's
          // fade, long enough to keep the overlay from flashing on every switch.
          duration: const Duration(milliseconds: 200),
          child: !noFunscriptLoaded
              ? const SizedBox.shrink(key: ValueKey("no_loading_overlay"))
              : inPlaylistTransition
              ? _overlayCard(
                  key: const ValueKey('transition_overlay'),
                  children: const [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Loading next…'),
                  ],
                )
              : _overlayCard(
                  key: const ValueKey('empty_overlay'),
                  children: [
                    const Icon(
                      Icons.movie_outlined,
                      size: 48,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Nothing playing',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      syncopathySimpleMode
                          ? 'Open a video and funscript to begin.'
                          : 'Pick something from your library to begin.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
