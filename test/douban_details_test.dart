import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/api/guangya_api.dart';

class _DoubanDetailsInterceptor extends Interceptor {
  Uri? requestedURI;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requestedURI = options.uri;
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: 200,
        data: const {'id': '1295644', 'title': '这个杀手不太冷'},
      ),
    );
  }
}

void main() {
  test('Douban details loads a movie directly by subject ID', () async {
    final interceptor = _DoubanDetailsInterceptor();
    final dio = Dio()..interceptors.add(interceptor);
    final api = GuangyaAPI(doubanDio: dio);

    final details = await api.doubanDetails(' 1295644 ');

    expect(details['id'], '1295644');
    expect(interceptor.requestedURI?.path, '/api/v2/movie/1295644');
    expect(interceptor.requestedURI?.queryParameters['apikey'], isNotEmpty);
  });

  test('Douban details rejects a non-numeric subject ID', () {
    final api = GuangyaAPI();

    expect(() => api.doubanDetails('abc'), throwsArgumentError);
  });
}
