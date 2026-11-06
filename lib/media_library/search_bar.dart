import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:syncopathy/helper/debouncer.dart';

class MediaSearchBar extends StatefulWidget {
  final Function(String) onFilterChanged;

  /// Shared query signal. When set, the field mirrors changes made by the
  /// other media-library presentation (Media tab vs fullscreen panel), so
  /// both show the same search text.
  final ReadonlySignal<String>? query;

  const MediaSearchBar({super.key, required this.onFilterChanged, this.query});

  @override
  State<MediaSearchBar> createState() => _MediaSearchBarState();
}

class _MediaSearchBarState extends State<MediaSearchBar> {
  late final TextEditingController _searchController;
  final Debouncer _debouncer = Debouncer(milliseconds: 200);

  void Function()? _queryEffectDispose;

  /// Guards against feeding a mirrored value back through the debounced
  /// callback that would write the same value to the shared signal.
  bool _applyingSharedQuery = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.query?.value ?? '');
    _searchController.addListener(_onSearchChanged);

    final query = widget.query;
    if (query != null) {
      _queryEffectDispose = effect(() {
        final value = query.value;
        if (_searchController.text == value) return;
        _applyingSharedQuery = true;
        _searchController.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        _applyingSharedQuery = false;
      });
    }
  }

  void _onSearchChanged() {
    if (_applyingSharedQuery) return;
    _debouncer.run(() => widget.onFilterChanged(_searchController.text));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          labelText: 'Search Videos',
          hintText: 'What are you looking for?',
          prefixIcon: const Icon(Icons.search),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12.0)),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _queryEffectDispose?.call();
    _searchController.dispose();
    _debouncer.dispose();
    super.dispose();
  }
}
