import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/media_library/filter/media_filter.dart';
import 'package:syncopathy/model/media_filter_presets_model.dart';
import 'package:syncopathy/persistence/entities/media_file.dart';

/// State shared by every presentation of the media library (the Media tab and
/// the fullscreen video player's slide-over panel).
///
/// The widgets themselves are recreated when the panel closes and reopens, but
/// the state they read lives here for the lifetime of the app. That keeps
/// filters, search, sorting, category selection and the current selection in
/// sync between the two presentations, and makes a reopened panel resume where
/// the previous one left off until the program exits.
class MediaLibraryState {
  final MediaFilterPresetsModel filterPresets;

  final MediaFilter mediaFilter = MediaFilter();
  final Signal<String> searchQuery = signal("");
  final SetSignal<MediaFile> selectedVideos = setSignal({});
  final Signal<bool> isFiltering = signal(false);
  final Signal<int?> randomSeed = signal(null);
  final Signal<int?> selectedCategoryFilter = signal<int?>(null);

  MediaLibraryState(this.filterPresets) {
    // Applied once, at startup: a subsequently opened panel must not reset the
    // filters the Media tab (or a previous panel session) already changed.
    filterPresets.activePreset.value?.snapshot.applyTo(mediaFilter);
  }
}
