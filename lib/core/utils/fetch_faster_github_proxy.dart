import 'dart:math';

import 'package:dio/dio.dart';

import '../logging/app_logger.dart';

const githubProxyCandidates = <String>[
  'https://gh-proxy.net/',
  'https://github.cnxiaobai.com/',
  'https://hub.gitmirror.com/',
  'https://www.5555.cab/',
  'https://ghproxy.xiaopa.cc/',
  'https://ghproxy.cfd/',
  'https://ghproxy.cc/',
  'https://ghproxy.monkeyray.net/',
  'https://cf.ghproxy.cc/',
  'https://gitproxy.mrhjx.cn/',
  'https://ghproxy.1888866.xyz/',
  'https://github.mlmle.cn/',
  'https://fastgit.cc/',
  'https://gh.1k.ink/',
  'https://ghproxy.net/',
  'https://github.boringhex.top/',
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://gh.dpik.top/',
  'https://github.chenc.dev/',
  'https://ghfile.geekertao.top/',
  'https://gitproxy.click/',
  'https://ghproxy.cn/',
  'https://down.npee.cn/',
  'https://github.cn86.dev/',
];

const _githubProbePath = 'https://github.com/favicon.ico';

Future<GithubProxyTestResult> fetchFasterGithubProxy({
  Dio? dio,
  int sampleSize = 20,
  Duration timeout = const Duration(milliseconds: 1800),
}) async {
  final proxies = githubProxyCandidates.toSet().toList();
  if (proxies.isEmpty) {
    return const GithubProxyTestResult.error('没有可用的 GitHub 加速地址');
  }
  final client = dio ?? Dio();
  client.options
    ..connectTimeout = timeout
    ..receiveTimeout = timeout
    ..sendTimeout = timeout
    ..followRedirects = false
    ..validateStatus = (status) => status != null && status < 500;
  final random = Random()..nextInt(1);
  final selected = proxies.toList()..shuffle(random);
  final tested = await Future.wait(
    selected
        .take(sampleSize.clamp(1, proxies.length))
        .map((proxy) => _testProxy(client, proxy)),
  );
  final available = tested.where((result) => result.available).toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  if (available.isEmpty) {
    AppLogger.warning('Upgrade', '未找到可用 GitHub 加速地址');
    return GithubProxyTestResult.error('未找到可用的 GitHub 加速地址', results: tested);
  }
  final fastest = available.first;
  AppLogger.info(
    'Upgrade',
    '最快 GitHub 加速地址：${fastest.url}，响应 ${fastest.time} ms',
  );
  return GithubProxyTestResult.success(fastest, available);
}

Future<GithubProxyResponse> _testProxy(
  Dio dio,
  String proxy,
) async {
  final stopwatch = Stopwatch()..start();
  try {
    final url = buildGithubProxyUrl(proxy, _githubProbePath);
    Response<dynamic> response;
    try {
      response = await dio.head<dynamic>(url);
    } on DioException {
      response = await dio.get<dynamic>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
    }
    stopwatch.stop();
    return GithubProxyResponse(
      url: proxy,
      time: stopwatch.elapsedMilliseconds,
      status: response.statusCode ?? 0,
    );
  } catch (_) {
    stopwatch.stop();
    return GithubProxyResponse(
      url: proxy,
      time: stopwatch.elapsedMilliseconds,
      status: 0,
    );
  }
}

String buildGithubProxyUrl(String proxy, String githubUrl) {
  final base = proxy.endsWith('/') ? proxy : '$proxy/';
  return '$base${unwrapGithubProxyUrl(githubUrl) ?? githubUrl}';
}

String? unwrapGithubProxyUrl(String url) {
  final value = url.trim();
  if (_isGithubUrl(value)) return value;
  for (final proxy in githubProxyCandidates) {
    final base = proxy.endsWith('/') ? proxy : '$proxy/';
    if (value.startsWith(base)) return value.substring(base.length);
  }
  return null;
}

bool isGithubDownloadUrl(String url) =>
    _isGithubUrl(unwrapGithubProxyUrl(url) ?? url);

bool _isGithubUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == 'github.com' ||
      host == 'raw.githubusercontent.com' ||
      host == 'objects.githubusercontent.com' ||
      host.endsWith('.githubusercontent.com');
}

class GithubProxyTestResult {
  final GithubProxyResponse? data;
  final List<GithubProxyResponse> results;
  final String message;
  final bool success;

  const GithubProxyTestResult.success(this.data, this.results)
    : message = '',
      success = true;
  const GithubProxyTestResult.error(this.message, {this.results = const []})
    : data = null,
      success = false;
}

class GithubProxyResponse {
  final String url;
  final int time;
  final int status;

  const GithubProxyResponse({
    required this.url,
    required this.time,
    required this.status,
  });

  bool get available => status >= 200 && status < 500;
}
