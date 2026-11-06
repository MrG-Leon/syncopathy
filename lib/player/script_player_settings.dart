import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:syncopathy/funscript_algo.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/focus_numeric_input.dart';
import 'package:syncopathy/model/player_model.dart';
import 'package:syncopathy/model/settings_model.dart';
import 'package:syncopathy/player/handy_native_hsp_mixin.dart';
import 'package:syncopathy/player/playback_session.dart';
import 'package:syncopathy/settings_overlay.dart';

class ScriptPlayerSettings extends StatefulWidget {
  const ScriptPlayerSettings({super.key});

  @override
  State<ScriptPlayerSettings> createState() => _ScriptPlayerSettingsState();
}

class _ScriptPlayerSettingsState extends State<ScriptPlayerSettings> {
  /// Width threshold above which the layout switches to a two-column layout.
  /// Below this it stacks cards vertically to stay usable on small windows.
  static const double _twoColumnBreakpoint = 1000;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useTwoColumns = constraints.maxWidth >= _twoColumnBreakpoint;

          // The Funscript card holds the most controls. Its children are split
          // into two groups so that when the card is laid out in a wide column
          // (or full-screen), the controls render side by side instead of being
          // stretched and pushed off-screen. On narrow widths it falls back to
          // a single stacked column.
          final funscriptGroups = <List<Widget>>[
            // Left group
            [
              _buildRdpEpsilonSettings(context),
              _buildSlewRateSettings(context),
              _buildIntensitySettings(context),
              _buildPchipSmoothSettings(context),
            ],
            // Right group
            [
              _buildInvertSettings(context),
              _buildRemapFullRangeSettings(context),
              _buildMaximizeStrokeRangeSettings(context),
              _buildWaveModulationSettings(context),
              _buildFunscriptStats(context),
            ],
          ];

          final funscriptCard = SettingsOverlay.settingsCard(
            // A large width hint so the card fills its column (the effective
            // width is clamped to the column's available space by settingsCard's
            // LayoutBuilder). This maximizes horizontal use for the two side-by-
            // side control groups instead of leaving a wide empty strip to the
            // right of a fixed 450px card.
            width: 1200,
            title: 'Funscript',
            children: useTwoColumns
                ? [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final group in funscriptGroups)
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: group,
                            ),
                          ),
                      ],
                    ),
                  ]
                : funscriptGroups.expand((g) => g).toList(),
          );

          final strokeRangeCard = SettingsOverlay.settingsCard(
            width: 450,
            title: 'Stroke Range',
            children: [_buildMinMaxSettings(context)],
          );

          final edgeModeConfigCard = SettingsOverlay.settingsCard(
            width: 1200,
            title: 'Edge Mode Config',
            children: [
              _buildEdgeModeConfigSettings(
                context,
                horizontal: useTwoColumns,
              ),
            ],
          );

          final timingCard = SettingsOverlay.settingsCard(
            width: 450,
            title: 'Timing',
            children: [_buildTimingSettings(context)],
          );

          // Wide layout: Funscript fills the left column, with Edge Mode Config
          // directly below it and sharing its width. Stroke Range and Timing
          // stack in a fixed-width right column. The right column keeps its
          // natural 450px width so the extra horizontal space goes entirely to
          // the left column.
          if (useTwoColumns) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      funscriptCard,
                      const SizedBox(height: 24),
                      edgeModeConfigCard,
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 450,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      strokeRangeCard,
                      const SizedBox(height: 24),
                      timingCard,
                    ],
                  ),
                ),
              ],
            );
          }

          // Narrow layout: stack vertically.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              funscriptCard,
              const SizedBox(height: 24),
              edgeModeConfigCard,
              const SizedBox(height: 24),
              strokeRangeCard,
              const SizedBox(height: 24),
              timingCard,
            ],
          );
        },
      ),
    );
  }

  Widget _buildSliderWithNumericInput(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    String? label,
    bool showNumericInput = true,
  }) {
    final slider = Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label ?? value.round().toString(),
      onChanged: onChanged,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: showNumericInput
          ? Row(
              children: [
                Expanded(flex: 3, child: slider),
                Expanded(
                  flex: 1,
                  child: FocusNumericInput(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
              ],
            )
          : slider,
    );
  }

  Widget _buildRdpEpsilonSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) {
        final rdpEpsilon = settings.rdpEpsilon.value;
        return Column(
          children: [
            SwitchListTile(
              title: const Text('Funscript Simplification (RDP Epsilon)'),
              subtitle: const Text(
                'Reduces the number of points in the funscript. Higher values mean more simplification.',
              ),
              value: rdpEpsilon >= 0,
              onChanged: (value) {
                settings.rdpEpsilon.value = value ? 7.0 : -1;
              },
              secondary: const Icon(Icons.timeline),
              isThreeLine: true,
            ),
            if (rdpEpsilon >= 0)
              _buildSliderWithNumericInput(
                context,
                value: rdpEpsilon,
                min: 0,
                max: 50,
                divisions: 50,
                onChanged: (value) {
                  settings.rdpEpsilon.value = value;
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildPchipSmoothSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) {
        final smoothInterval = settings.pchipSmoothInterval.value;
        return Column(
          children: [
            SwitchListTile(
              title: const Text('Spline Smoothing'),
              subtitle: const Text(
                'Modify the funscript adding spline smoothing.',
              ),
              value: smoothInterval != null,
              onChanged: (value) {
                settings.pchipSmoothInterval.value = value ? 50 : null;
              },
              secondary: const Icon(Icons.route_rounded),
              isThreeLine: true,
            ),
            if (smoothInterval != null) ...[
              _buildSliderWithNumericInput(
                context,
                value: smoothInterval.toDouble(),
                min: 50,
                max: 100,
                divisions: 5,
                onChanged: (value) {
                  settings.pchipSmoothInterval.value = value.toInt();
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildSlewRateSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) {
        final slewMaxRateOfChange = settings.slewMaxRateOfChange.value;
        return Column(
          children: [
            SwitchListTile(
              title: const Text('Slew Rate Limit'),
              subtitle: const Text(
                'Modify the funscript limiting the rate of change, preventing jerky movements. Measured in percent per second.',
              ),
              value: slewMaxRateOfChange >= 0,
              onChanged: (value) {
                settings.slewMaxRateOfChange.value = value ? 400 : -1;
              },
              secondary: const Icon(Icons.speed),
              isThreeLine: true,
            ),
            if (slewMaxRateOfChange >= 0)
              _buildSliderWithNumericInput(
                context,
                value: slewMaxRateOfChange,
                min: 100,
                max: 1000,
                divisions: 90,
                onChanged: (value) {
                  settings.slewMaxRateOfChange.value = value;
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildInvertSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        title: const Text('Invert'),
        subtitle: const Text('Inverts the funscript actions.'),
        value: settings.invert.value,
        onChanged: (value) {
          settings.invert.value = value;
        },
        secondary: const Icon(Icons.swap_vert),
        isThreeLine: true,
      ),
    );
  }

  Widget _buildRemapFullRangeSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        title: const Text('Remap to Full Range'),
        subtitle: const Text(
          "Remaps the funscript actions to use the full 0-100 range. The Handy will still remap into the range specified by the stroke range setting.",
        ),
        value: settings.remapFullRange.value,
        onChanged: (value) {
          settings.remapFullRange.value = value;
        },
        secondary: const Icon(Icons.fullscreen),
        isThreeLine: true,
      ),
    );
  }

  Widget _buildMaximizeStrokeRangeSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        title: const Text('Maximize Stroke Range'),
        subtitle: const Text(
          'Stretches every stroke so peaks hit 100 and valleys hit 0, preserving transition shapes.',
        ),
        value: settings.maximizeStrokeRange.value,
        onChanged: (value) {
          settings.maximizeStrokeRange.value = value;
        },
        secondary: const Icon(Icons.expand),
        isThreeLine: true,
      ),
    );
  }

  Widget _buildWaveModulationSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) {
        final enabled = settings.waveModulationEnabled.value;
        return Column(
          children: [
            SwitchListTile(
              title: const Text('Wave Modulation'),
              subtitle: const Text(
                'Modulates the funscript with a periodic carrier wave (sine/triangle), preserving the original motion trend.',
              ),
              value: enabled,
              onChanged: (value) {
                settings.waveModulationEnabled.value = value;
              },
              secondary: const Icon(Icons.waves),
              isThreeLine: true,
            ),
            if (enabled) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    const Text('Shape'),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SegmentedButton<WaveShape>(
                        segments: const [
                          ButtonSegment(
                            value: WaveShape.sine,
                            label: Text('Sine'),
                            icon: Icon(Icons.show_chart),
                          ),
                          ButtonSegment(
                            value: WaveShape.triangle,
                            label: Text('Triangle'),
                            icon: Icon(Icons.change_history),
                          ),
                        ],
                        selected: {settings.waveShape.value},
                        onSelectionChanged: (selection) {
                          settings.waveShape.value = selection.first;
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _buildSliderWithNumericInput(
                context,
                value: settings.waveReductionPercentage.value,
                min: 0,
                max: 100,
                divisions: 100,
                onChanged: (value) {
                  settings.waveReductionPercentage.value = value;
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Stroke Reduction: ${settings.waveReductionPercentage.value.round()}%  (higher = stronger wave, weaker original)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _buildSliderWithNumericInput(
                context,
                value: settings.wavePeriodSec.value,
                min: 1,
                max: 60,
                divisions: 118,
                onChanged: (value) {
                  settings.wavePeriodSec.value = value;
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Cycle Duration: ${settings.wavePeriodSec.value.toStringAsFixed(1)}s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildFunscriptStats(BuildContext context) {
    final playerModel = context.read<PlayerModel>();
    return SignalBuilder(
      builder: (context) {
        final currentlyOpen = playerModel.currentlyOpen.value;
        if (currentlyOpen == null) return const SizedBox.shrink();
        final funscript = currentlyOpen.funscript;

        final speed = funscript.averageSpeed.value;
        final min = funscript.averageMin.value;
        final max = funscript.averageMax.value;

        return ListTile(
          leading: const Icon(Icons.analytics_outlined),
          title: const Text('Processed Script Stats'),
          subtitle: Text(
            'Avg Speed: ${speed.toStringAsFixed(1)} | Avg Min: ${min.round()} | Avg Max: ${max.round()}',
          ),
        );
      },
    );
  }

  Widget _buildIntensitySettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) {
        final intensity = settings.intensity.value;
        return Column(
          children: [
            SwitchListTile(
              title: const Text('Intensity'),
              subtitle: Text(
                intensity == null
                    ? 'Current: Off. Scales the stroke length when enabled.'
                    : 'Current: ${(intensity * 100).round()}%. Below 100% reduces it; above 100% increases it and raises speed.',
              ),
              value: intensity != null,
              onChanged: (value) {
                settings.setIntensity(value ? 1.0 : null);
              },
              secondary: const Icon(Icons.bolt),
              isThreeLine: true,
            ),
            if (intensity != null)
              _buildSliderWithNumericInput(
                context,
                value: intensity * 100.0,
                min: 0,
                max: 500,
                divisions: 50,
                label: '${(intensity * 100).round()}%',
                showNumericInput: false,
                onChanged: (value) {
                  settings.setIntensity(value / 100.0);
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildMinMaxSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();

    return SignalBuilder(
      builder: (context) {
        final currentRange = settings.minMaxRange.value;
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                valueIndicatorColor: Theme.of(context).colorScheme.primary,
              ),
              child: RangeSlider(
                values: currentRange,
                min: 0,
                max: 100,
                divisions: 100,
                labels: RangeLabels(
                  settings.min.value.round().toString(),
                  settings.max.value.round().toString(),
                ),
                onChanged: (values) {
                  settings.min.value = values.start.toInt();
                  settings.max.value = values.end.toInt();
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Expanded(
                  child: FocusNumericInput(
                    label: 'Min',
                    value: settings.min.value.toDouble(),
                    min: 0,
                    max: 100,
                    onChanged: (value) {
                      settings.min.value = value.toInt();
                      if (settings.min.value > settings.max.value) {
                        settings.max.value = settings.min.value;
                      }
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FocusNumericInput(
                    label: 'Max',
                    value: settings.max.value.toDouble(),
                    min: 0,
                    max: 100,
                    onChanged: (value) {
                      settings.max.value = value.toInt();
                      if (settings.max.value < settings.min.value) {
                        settings.min.value = settings.max.value;
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildEdgeModeConfigSettings(
    BuildContext context, {
    required bool horizontal,
  }) {
    final settings = context.read<SettingsModel>();
    return SignalBuilder(
      builder: (context) {
        final delaySec = settings.edgeModeAutoToggleDelaySeconds.value.clamp(
          SettingsModel.edgeModeAutoToggleDelayMinSeconds,
          SettingsModel.edgeModeAutoToggleDelayMaxSeconds,
        );
        final intensityStepPercent =
            (settings.edgeModeIntensityStep.value * 100).round();
        final delayStepSeconds = settings.edgeModeDelayStepSeconds.value;
        final intensityFloorPercent =
            (settings.edgeModeIntensityFloor.value * 100).round();
        final delayCeilingSeconds = settings.edgeModeDelayCeilingSeconds.value;

        final edgeTimesTile = ListTile(
          leading: const Icon(Icons.repeat),
          title: const Text('Edge times'),
          trailing: Text(
            '${settings.edgeModeActivationCount.value}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        );

        final currentDelayGroup = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEdgeModeConfigLabel(context, 'Current delay', '${delaySec}s'),
            _buildEdgeModeConfigSlider(
              context,
              value: delaySec.toDouble(),
              min: SettingsModel.edgeModeAutoToggleDelayMinSeconds.toDouble(),
              max: SettingsModel.edgeModeAutoToggleDelayMaxSeconds.toDouble(),
              divisions:
                  SettingsModel.edgeModeAutoToggleDelayMaxSeconds -
                  SettingsModel.edgeModeAutoToggleDelayMinSeconds,
              label: '${delaySec}s',
              onChanged: (v) => settings.setEdgeModeDelay(v.round()),
            ),
          ],
        );

        final stats = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [edgeTimesTile, currentDelayGroup],
        );

        final intensityGroup = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEdgeModeConfigLabel(
              context,
              'Intensity reduction',
              '$intensityStepPercent%',
            ),
            _buildEdgeModeConfigSlider(
              context,
              value: intensityStepPercent.toDouble(),
              min: SettingsModel.edgeModeIntensityStepMin * 100.0,
              max: SettingsModel.edgeModeIntensityStepMax * 100.0,
              divisions:
                  ((SettingsModel.edgeModeIntensityStepMax -
                          SettingsModel.edgeModeIntensityStepMin) *
                      100)
                      .round(),
              label: '$intensityStepPercent%',
              onChanged: (v) =>
                  settings.edgeModeIntensityStep.value = v / 100.0,
            ),
            _buildEdgeModeConfigLabel(
              context,
              'Intensity floor',
              '$intensityFloorPercent%',
            ),
            _buildEdgeModeConfigSlider(
              context,
              value: intensityFloorPercent.toDouble(),
              min: SettingsModel.edgeModeIntensityFloorMin * 100.0,
              max: SettingsModel.edgeModeIntensityFloorMax * 100.0,
              divisions:
                  ((SettingsModel.edgeModeIntensityFloorMax -
                          SettingsModel.edgeModeIntensityFloorMin) *
                      100)
                      .round(),
              label: '$intensityFloorPercent%',
              onChanged: (v) =>
                  settings.edgeModeIntensityFloor.value = v / 100.0,
            ),
          ],
        );

        final delayGroup = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEdgeModeConfigLabel(
              context,
              'Delay increase',
              '${delayStepSeconds}s',
            ),
            _buildEdgeModeConfigSlider(
              context,
              value: delayStepSeconds.toDouble(),
              min: SettingsModel.edgeModeDelayStepMinSeconds.toDouble(),
              max: SettingsModel.edgeModeDelayStepMaxSeconds.toDouble(),
              divisions:
                  SettingsModel.edgeModeDelayStepMaxSeconds -
                  SettingsModel.edgeModeDelayStepMinSeconds,
              label: '${delayStepSeconds}s',
              onChanged: (v) =>
                  settings.edgeModeDelayStepSeconds.value = v.round(),
            ),
            _buildEdgeModeConfigLabel(
              context,
              'Delay ceiling',
              '${delayCeilingSeconds}s',
            ),
            _buildEdgeModeConfigSlider(
              context,
              value: delayCeilingSeconds.toDouble(),
              min: SettingsModel.edgeModeDelayCeilingMinSeconds.toDouble(),
              max: SettingsModel.edgeModeDelayCeilingMaxSeconds.toDouble(),
              divisions:
                  SettingsModel.edgeModeDelayCeilingMaxSeconds -
                  SettingsModel.edgeModeDelayCeilingMinSeconds,
              label: '${delayCeilingSeconds}s',
              onChanged: (v) =>
                  settings.edgeModeDelayCeilingSeconds.value = v.round(),
            ),
          ],
        );

        final afterEdgeModeHeader = ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('After Edge Mode'),
          subtitle: const Text(
            'Applied after the automatic toggle-back. Manual exits leave the current values unchanged.',
          ),
          isThreeLine: true,
        );

        if (!horizontal) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              stats,
              const Divider(height: 24),
              afterEdgeModeHeader,
              intensityGroup,
              delayGroup,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: edgeTimesTile),
                const SizedBox(width: 24),
                Expanded(child: currentDelayGroup),
              ],
            ),
            const Divider(height: 24),
            afterEdgeModeHeader,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: intensityGroup),
                const SizedBox(width: 24),
                Expanded(child: delayGroup),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildEdgeModeConfigLabel(
    BuildContext context,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }

  Widget _buildEdgeModeConfigSlider(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        valueIndicatorColor: Theme.of(context).colorScheme.primary,
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildTimingSettings(BuildContext context) {
    final settings = context.read<SettingsModel>();
    final activeSession = context.read<ActivePlaybackSession>();
    final playerModel = context.read<PlayerModel>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          leading: Icon(Icons.speed_outlined),
          title: Text('Playback Speed'),
          subtitle: Text('Adjust playback speed while the video is paused.'),
          isThreeLine: true,
        ),
        SignalBuilder(
          builder: (context) {
            // Aimed at whichever session owns playback: with an external
            // player in charge this was retuning an idle mpv while the script
            // kept running at the old rate. A session that will not accept a
            // speed change disables the slider rather than swallowing it.
            final session = activeSession.session.value;
            final canSetSpeed =
                session.paused.value &&
                session.supports(PlaybackCapability.setSpeed);
            return Slider(
              value: session.playbackSpeed.value,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: session.playbackSpeed.value.toStringAsFixed(2),
              onChanged: canSetSpeed ? session.setSpeed : null,
            );
          },
        ),
        const ListTile(
          leading: Icon(Icons.timer_outlined),
          title: Text('Timing Offset'),
          subtitle: Text(
            'Adjusts the timing of the script. A positive value makes actions happen earlier, a negative value makes them happen later. Change is applied immediately.',
          ),
          isThreeLine: true,
        ),
        SignalBuilder(
          builder: (context) => _buildSliderWithNumericInput(
            context,
            value: settings.offsetMs.value.toDouble(),
            min: -500,
            max: 500,
            divisions: 200,
            onChanged: (value) {
              settings.offsetMs.value = value.toInt();
            },
          ),
        ),
        SignalBuilder(
          builder: (context) {
            final currentDelta =
                playerModel.playerBackend.value?.debugPlaybackDelta.value;
            if (currentDelta == null) return const SizedBox.shrink();
            return ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text('Playback Delta: $currentDelta ms'),
              subtitle: const Text(
                "This is calculated by taking the current video player time and subtracting the current time the handy sends back.\nTake this with a grain of salt but it's useful for tweaking the time offset.",
              ),
              isThreeLine: true,
            );
          },
        ),
        SignalBuilder(
          builder: (context) {
            final backend = playerModel.playerBackend.value;
            if (backend case HandyNativeHspMixin hspMixin) {
              final hspState = hspMixin.hspStateAdapter.value;
              if (hspState == null) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.bug_report),
                title: Text('Stats for nerds'),
                subtitle: Text(
                  hspState.toString(),
                  style: GoogleFonts.robotoMono(),
                ),
                isThreeLine: true,
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }
}
