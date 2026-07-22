/// The top-level surfaces in the media workspace.  Keeping this separate
/// from widgets prevents combinations such as "home + search + management"
/// from being represented by several nullable fields.
enum MediaWorkspaceView { home, library, search, management }

enum MediaLibraryBrowseFilter { all, movies, series, collections, unmatched }

enum MediaLibrarySort { addedAt, releaseDate, title, doubanRating, tmdbRating }

enum MediaSortDirection { ascending, descending }

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
