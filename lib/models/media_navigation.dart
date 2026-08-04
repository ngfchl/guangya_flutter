import 'media_library.dart' show MediaLibraryItem;

const _mediaGenreLabels = <String, String>{
  'adventure': '冒险',
  'drama': '剧情',
  'action': '动作',
  'animation': '动画',
  'comedy': '喜剧',
  'family': '家庭',
  'mystery': '悬疑',
  'crime': '犯罪',
  'documentary': '纪录',
  '纪录片': '纪录',
  'western': '西部',
  'science fiction': '科幻',
  'sci-fi': '科幻',
  'fantasy': '奇幻',
  'war': '战争',
  'history': '历史',
  'horror': '恐怖',
  'thriller': '惊悚',
  'romance': '爱情',
  'music': '音乐',
  'tv movie': '电视电影',
  'kids': '儿童',
  'reality': '真人秀',
  'variety': '综艺',
  'wuxia': '武侠',
  'costume': '古装',
  'film noir': '黑色',
  'film-noir': '黑色',
  'short': '短片',
  'action & adventure': '动作冒险',
  'sci-fi & fantasy': '科幻奇幻',
  'war & politics': '战争政治',
  'soap': '肥皂剧',
  'news': '新闻',
  'talk': '脱口秀',
};

const _mediaCountryLabels = <String, String>{
  'CN': '中国大陆',
  'TW': '中国台湾',
  'HK': '中国香港',
  'MO': '中国澳门',
  'US': '美国',
  'GB': '英国',
  'JP': '日本',
  'KR': '韩国',
  'FR': '法国',
  'DE': '德国',
  'IT': '意大利',
  'ES': '西班牙',
  'IN': '印度',
  'CA': '加拿大',
  'AU': '澳大利亚',
  'NZ': '新西兰',
  'RU': '俄罗斯',
  'TH': '泰国',
  'SE': '瑞典',
  'FI': '芬兰',
  'DK': '丹麦',
  'NO': '挪威',
  'IE': '爱尔兰',
  'NL': '荷兰',
  'BE': '比利时',
  'AT': '奥地利',
  'CH': '瑞士',
  'GE': '格鲁吉亚',
  'LT': '立陶宛',
  'MX': '墨西哥',
  'BR': '巴西',
  'AR': '阿根廷',
  'CL': '智利',
  'CO': '哥伦比亚',
  'TR': '土耳其',
  'ID': '印度尼西亚',
  'SG': '新加坡',
  'MY': '马来西亚',
  'PH': '菲律宾',
  'VN': '越南',
  'PL': '波兰',
  'CZ': '捷克',
  'GR': '希腊',
  'PT': '葡萄牙',
  'HU': '匈牙利',
  'RO': '罗马尼亚',
  'BG': '保加利亚',
  'RS': '塞尔维亚',
  'UA': '乌克兰',
  'ZA': '南非',
  'IL': '以色列',
  'IR': '伊朗',
  'NG': '尼日利亚',
  'QA': '卡塔尔',
  'IS': '冰岛',
  'EE': '爱沙尼亚',
  'LV': '拉脱维亚',
  'SK': '斯洛伐克',
  'SI': '斯洛文尼亚',
  'HR': '克罗地亚',
};

String normalizeMediaGenre(String value) {
  final genre = value.trim();
  if (genre.isEmpty) return '';
  return _mediaGenreLabels[genre.toLowerCase()] ?? genre;
}

String normalizeMediaCountry(String value) {
  final country = value.trim();
  if (country.isEmpty) return '';
  final upper = country.toUpperCase();
  if (_mediaCountryLabels.containsKey(upper)) return upper;
  for (final entry in _mediaCountryLabels.entries) {
    if (entry.value == country) return entry.key;
  }
  if (country == '中国') return 'CN';
  return country.length == 2 ? upper : country;
}

String mediaCountryLabel(String value) {
  final country = normalizeMediaCountry(value);
  return _mediaCountryLabels[country] ?? country;
}

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
    final selectedGenres = genres.map(normalizeMediaGenre).toSet();
    if (selectedGenres.isNotEmpty &&
        item.genres.every(
          (genre) => !selectedGenres.contains(normalizeMediaGenre(genre)),
        )) {
      return false;
    }
    if (resolutions.isNotEmpty &&
        !resolutions.contains(_resolutionOf(item.file.name))) {
      return false;
    }
    final selectedCountries = countries.map(normalizeMediaCountry).toSet();
    if (selectedCountries.isNotEmpty &&
        item.originCountries.every(
          (country) =>
              !selectedCountries.contains(normalizeMediaCountry(country)),
        )) {
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
