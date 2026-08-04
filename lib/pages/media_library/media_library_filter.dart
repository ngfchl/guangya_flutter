part of '../media_library_page.dart';

/// 影视库筛选面板。按类别分组的单选 chip，顶部展开式。
/// 类别顺序与图片对齐：影视分类/类型/分辨率/国家地区/发行年份/匹配状态/是否已观看。
class MediaLibraryFilterPanel extends StatelessWidget {
  final MediaLibraryFilter filter;
  final Set<String> availableGenres;
  final Set<String> availableCountries;
  final Set<String> availableWatchedKeys; // 已观看维度可选项（受 watch_history 是否有记录影响）
  final void Function(MediaLibraryFilter next) onFilter;
  final VoidCallback onCollapse;

  const MediaLibraryFilterPanel({
    super.key,
    required this.filter,
    required this.availableGenres,
    required this.availableCountries,
    required this.availableWatchedKeys,
    required this.onFilter,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final sections = <_FilterSection>[
      _FilterSection(
        title: '影视分类',
        options: const [
          _FilterOption(value: 'movie', label: '电影'),
          _FilterOption(value: 'tv', label: '电视剧'),
        ],
        selected: filter.kinds,
        onToggle: (value) => onFilter(filter.copyWith(
          kinds: _toggle(filter.kinds, value),
        )),
      ),
      _FilterSection(
        title: '类型',
        options: _genreOptions(availableGenres),
        selected: filter.genres,
        onToggle: (value) => onFilter(filter.copyWith(
          genres: _toggle(filter.genres, value),
        )),
      ),
      _FilterSection(
        title: '分辨率',
        options: const [
          _FilterOption(value: '4K', label: '4K'),
          _FilterOption(value: '1080P', label: '1080P'),
          _FilterOption(value: '720P', label: '720P'),
          _FilterOption(value: 'other', label: '其他'),
        ],
        selected: filter.resolutions,
        onToggle: (value) => onFilter(filter.copyWith(
          resolutions: _toggle(filter.resolutions, value),
        )),
      ),
      if (availableCountries.isNotEmpty)
        _FilterSection(
          title: '发行地',
          options: availableCountries
              .map((c) => _FilterOption(value: c, label: _countryLabel(c)))
              .toList()
            ..sort((a, b) => a.label.compareTo(b.label)),
          selected: filter.countries,
          onToggle: (value) => onFilter(filter.copyWith(
            countries: _toggle(filter.countries, value),
          )),
        ),
      _FilterSection(
        title: '发行年份',
        options: const [
          _FilterOption(value: 'thisYear', label: '今年'),
          _FilterOption(value: '2020s', label: '2020 年代'),
          _FilterOption(value: '2010s', label: '2010 年代'),
          _FilterOption(value: '2000s', label: '2000 年代'),
          _FilterOption(value: '1990s', label: '1990 年代'),
          _FilterOption(value: '1980s', label: '1980 年代'),
          _FilterOption(value: '1970s', label: '1970 年代'),
          _FilterOption(value: 'other', label: '其他'),
        ],
        selected: filter.decades,
        onToggle: (value) => onFilter(filter.copyWith(
          decades: _toggle(filter.decades, value),
        )),
      ),
      _FilterSection(
        title: '匹配状态',
        options: const [
          _FilterOption(value: 'matched', label: '已匹配'),
          _FilterOption(value: 'unmatched', label: '未匹配'),
        ],
        selected: filter.matchStates,
        onToggle: (value) => onFilter(filter.copyWith(
          matchStates: _toggle(filter.matchStates, value),
        )),
      ),
      if (availableWatchedKeys.isNotEmpty)
        _FilterSection(
          title: '是否已观看',
          options: const [
            _FilterOption(value: 'watched', label: '已观看'),
            _FilterOption(value: 'unwatched', label: '未观看'),
          ],
          selected: filter.watchedStates,
          onToggle: (value) => onFilter(filter.copyWith(
            watchedStates: _toggle(filter.watchedStates, value),
          )),
        ),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: cs.card,
        border: Border(
          bottom: BorderSide(color: cs.border, width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final section in sections)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      section.title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: cs.mutedForeground,
                      ),
                    ),
                  ),
                  for (final opt in section.options)
                    _FilterChip(
                      label: opt.label,
                      selected: section.selected.contains(opt.value),
                      onTap: () => section.onToggle(opt.value),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 单选语义：点未选的换成它，点已选的清空该维度。
  static Set<String> _toggle(Set<String> source, String value) {
    if (source.contains(value)) return const {};
    return {value};
  }

  /// 「类型」分组选项：固定候选清单（TMDB genre 英文名作 value，中文作 label）+ 当前库里已出现但不在清单内的补全。
  /// value 用英文是因为 item.genres 存的是 TMDB 原始英文名（Adventure/Drama 等），matches 比对需与之对齐。
  static List<_FilterOption> _genreOptions(Set<String> availableGenres) {
    const fixed = <_FilterOption>[
      _FilterOption(value: 'Adventure', label: '冒险'),
      _FilterOption(value: 'Drama', label: '剧情'),
      _FilterOption(value: 'Action', label: '动作'),
      _FilterOption(value: 'Animation', label: '动画'),
      _FilterOption(value: 'Comedy', label: '喜剧'),
      _FilterOption(value: 'Family', label: '家庭'),
      _FilterOption(value: 'Mystery', label: '悬疑'),
      _FilterOption(value: 'Crime', label: '犯罪'),
      _FilterOption(value: 'Documentary', label: '纪录'),
      _FilterOption(value: 'Western', label: '西部'),
      _FilterOption(value: 'Science Fiction', label: '科幻'),
      _FilterOption(value: 'Fantasy', label: '奇幻'),
      _FilterOption(value: 'War', label: '战争'),
      _FilterOption(value: 'History', label: '历史'),
      _FilterOption(value: 'Horror', label: '恐怖'),
      _FilterOption(value: 'Thriller', label: '惊悚'),
      _FilterOption(value: 'Romance', label: '爱情'),
      _FilterOption(value: 'Music', label: '音乐'),
      _FilterOption(value: 'TV Movie', label: '电视电影'),
      _FilterOption(value: 'Kids', label: '儿童'),
      _FilterOption(value: 'Reality', label: '真人秀'),
      _FilterOption(value: 'Variety', label: '综艺'),
      _FilterOption(value: 'Wuxia', label: '武侠'),
      _FilterOption(value: 'Costume', label: '古装'),
      _FilterOption(value: 'Film Noir', label: '黑色'),
      _FilterOption(value: 'Short', label: '短片'),
    ];
    final fixedValues = fixed.map((e) => e.value).toSet();
    final extra = availableGenres
        .where((g) => !fixedValues.contains(g))
        .map((g) => _FilterOption(value: g, label: g))
        .toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return [...fixed, ...extra];
  }

  static String _countryLabel(String code) {
    return switch (code) {
      'CN' => '中国',
      'TW' => '中国台湾',
      'HK' => '中国香港',
      'US' => '美国',
      'GB' => '英国',
      'JP' => '日本',
      'KR' => '韩国',
      'FR' => '法国',
      'DE' => '德国',
      'IT' => '意大利',
      'ES' => '西班牙',
      'IN' => '印度',
      'CA' => '加拿大',
      'AU' => '澳大利亚',
      'RU' => '俄罗斯',
      'TH' => '泰国',
      'SE' => '瑞典',
      'FI' => '芬兰',
      'IE' => '爱尔兰',
      'NL' => '荷兰',
      'BE' => '比利时',
      'AT' => '奥地利',
      'MX' => '墨西哥',
      'BR' => '巴西',
      'AR' => '阿根廷',
      'TR' => '土耳其',
      'ID' => '印度尼西亚',
      'SG' => '新加坡',
      'BG' => '保加利亚',
      'RS' => '塞尔维亚',
      _ => code,
    };
  }
}

class _FilterSection {
  final String title;
  final List<_FilterOption> options;
  final Set<String> selected;
  final void Function(String value) onToggle;

  const _FilterSection({
    required this.title,
    required this.options,
    required this.selected,
    required this.onToggle,
  });
}

class _FilterOption {
  final String value;
  final String label;

  const _FilterOption({required this.value, required this.label});
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withValues(alpha: 0.12) : cs.secondary,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? cs.primary.withValues(alpha: 0.6) : cs.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? cs.primary : cs.foreground,
          ),
        ),
      ),
    );
  }
}
