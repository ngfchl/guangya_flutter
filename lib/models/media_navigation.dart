import 'media_library.dart' show MediaLibraryItem;

/// The top-level surfaces in the media workspace.  Keeping this separate
/// from widgets prevents combinations such as "home + search + management"
/// from being represented by several nullable fields.
enum MediaWorkspaceView { home, library, search, management }

enum MediaLibraryBrowseFilter { all, movies, series, collections, unmatched }

enum MediaLibrarySort { addedAt, releaseDate, title, doubanRating, tmdbRating }

enum MediaSortDirection { ascending, descending }

/// 影视库筛选维度。每个维度维护一组「已选值」，空集合表示「全部」。
/// 值统一用字符串：枚举取 name、年份取年代标签（如 "2020s"）、其它取原始字符串。
class MediaLibraryFilter {
  final Set<String> kinds;
  final Set<String> genres;
  final Set<String> resolutions;
  final Set<String> countries;
  final Set<String> decades;
  final Set<String> matchStates;
  final Set<String> watchedStates;

  const MediaLibraryFilter({
    this.kinds = const {},
    this.genres = const {},
    this.resolutions = const {},
    this.countries = const {},
    this.decades = const {},
    this.matchStates = const {},
    this.watchedStates = const {},
  });

  bool get isActive =>
      kinds.isNotEmpty ||
      genres.isNotEmpty ||
      resolutions.isNotEmpty ||
      countries.isNotEmpty ||
      decades.isNotEmpty ||
      matchStates.isNotEmpty ||
      watchedStates.isNotEmpty;

  MediaLibraryFilter copyWith({
    Set<String>? kinds,
    Set<String>? genres,
    Set<String>? resolutions,
    Set<String>? countries,
    Set<String>? decades,
    Set<String>? matchStates,
    Set<String>? watchedStates,
  }) {
    return MediaLibraryFilter(
      kinds: kinds ?? this.kinds,
      genres: genres ?? this.genres,
      resolutions: resolutions ?? this.resolutions,
      countries: countries ?? this.countries,
      decades: decades ?? this.decades,
      matchStates: matchStates ?? this.matchStates,
      watchedStates: watchedStates ?? this.watchedStates,
    );
  }

  /// 按 item 维度判定是否通过当前筛选（已在 UI 层做过 kind 预筛的项这里跳过 kinds 维度）
  bool matches(MediaLibraryItem item, {bool skipKinds = false}) {
    if (genres.isNotEmpty &&
        item.genres.every((g) => !genres.contains(g))) {
      return false;
    }
    if (resolutions.isNotEmpty &&
        !resolutions.contains(_resolutionOf(item.file.name))) {
      return false;
    }
    if (countries.isNotEmpty &&
        item.originCountries.every((c) => !countries.contains(c))) {
      return false;
    }
    if (decades.isNotEmpty && !decades.contains(_decadeOf(item.year))) {
      return false;
    }
    if (matchStates.isNotEmpty &&
        !matchStates.contains(item.isMatched ? 'matched' : 'unmatched')) {
      return false;
    }
    // watchedStates 由调用方补 watch_history 判定，这里跳过
    return true;
  }

  static String _resolutionOf(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.contains('4k') || lower.contains('2160p')) return '4K';
    if (lower.contains('1080p')) return '1080P';
    if (lower.contains('720p')) return '720P';
    return 'other';
  }

  static String _decadeOf(String year) {
    final y = int.tryParse(year);
    if (y == null || y <= 0) return 'other';
    if (y == DateTime.now().year) return 'thisYear';
    final d = (y ~/ 10) * 10;
    if (d >= 1970 && d <= 2020) return '${d}s';
    return 'other';
  }
}

extension MediaSortDirectionTitle on MediaSortDirection {
  String get title => switch (this) {
    MediaSortDirection.ascending => '升序',
    MediaSortDirection.descending => '降序',
  };
}

extension MediaLibrarySortTitle on MediaLibrarySort {
  String get title => switch (this) {
    MediaLibrarySort.addedAt => '入库时间',
    MediaLibrarySort.releaseDate => '发布时间',
    MediaLibrarySort.title => '标题',
    MediaLibrarySort.doubanRating => '豆瓣评分',
    MediaLibrarySort.tmdbRating => 'TMDB 评分',
  };
}

class MediaNavigationState {
  final MediaWorkspaceView view;
  final MediaLibraryBrowseFilter filter;
  final String? query;
  final MediaWorkspaceView? returnView;
  final MediaLibraryBrowseFilter? returnFilter;

  const MediaNavigationState({
    this.view = MediaWorkspaceView.home,
    this.filter = MediaLibraryBrowseFilter.all,
    this.query,
    this.returnView,
    this.returnFilter,
  });

  bool get isHome => view == MediaWorkspaceView.home;
  bool get isLibrary => view == MediaWorkspaceView.library;
  bool get isSearch => view == MediaWorkspaceView.search;
  bool get isManagement => view == MediaWorkspaceView.management;

  MediaNavigationState showHome() =>
      const MediaNavigationState(view: MediaWorkspaceView.home);

  MediaNavigationState showLibrary({
    MediaLibraryBrowseFilter filter = MediaLibraryBrowseFilter.all,
  }) => MediaNavigationState(view: MediaWorkspaceView.library, filter: filter);

  MediaNavigationState showManagement() =>
      const MediaNavigationState(view: MediaWorkspaceView.management);

  MediaNavigationState openSearch(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return this;
    final baseView = isSearch
        ? (returnView ?? MediaWorkspaceView.library)
        : view;
    final baseFilter = isSearch
        ? (returnFilter ?? MediaLibraryBrowseFilter.all)
        : filter;
    return MediaNavigationState(
      view: MediaWorkspaceView.search,
      filter: baseFilter,
      query: normalized,
      returnView: baseView,
      returnFilter: baseFilter,
    );
  }

  MediaNavigationState closeSearch() => MediaNavigationState(
    view: returnView ?? MediaWorkspaceView.library,
    filter: returnFilter ?? MediaLibraryBrowseFilter.all,
  );

  @override
  bool operator ==(Object other) {
    return other is MediaNavigationState &&
        other.view == view &&
        other.filter == filter &&
        other.query == query &&
        other.returnView == returnView &&
        other.returnFilter == returnFilter;
  }

  @override
  int get hashCode =>
      Object.hash(view, filter, query, returnView, returnFilter);

  @override
  String toString() =>
      'MediaNavigationState('
      'view: $view, filter: $filter, query: $query, '
      'returnView: $returnView, returnFilter: $returnFilter)';
}
