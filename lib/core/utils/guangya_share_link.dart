class GuangyaShareLink {
  final String shareID;
  final String url;
  final String? title;
  final String code;

  const GuangyaShareLink({
    required this.shareID,
    required this.url,
    this.title,
    this.code = '',
  });

  static final _urlPattern = RegExp(
    r'https?://(?:www\.)?guangyapan\.com/s/([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );
  static final _codePattern = RegExp(
    r'(?:提取码|访问码|密码)\s*[:：]?\s*([A-Za-z0-9]{1,12})',
    caseSensitive: false,
  );

  static GuangyaShareLink? tryParse(String text) {
    final match = _urlPattern.firstMatch(text);
    if (match == null) return null;
    final shareID = match.group(1)!;
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    String? title;
    for (final line in lines) {
      if (_urlPattern.hasMatch(line) || _codePattern.hasMatch(line)) continue;
      title = line;
      break;
    }
    return GuangyaShareLink(
      shareID: shareID,
      url: match.group(0)!,
      title: title,
      code: _codePattern.firstMatch(text)?.group(1) ?? '',
    );
  }
}
