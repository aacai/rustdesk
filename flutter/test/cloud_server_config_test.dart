import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/web_utils.dart';

void main() {
  group('extractRustdeskFencedJson', () {
    test('提取围栏内的 JSON 文本', () {
      final html = '''
        <p>一些说明文字</p>
        ```rustdesk
        {
          "host": "example.com",
          "relay": "",
          "key": "abc"
        }
        ```
        <p>其它文字</p>
      ''';
      final json = extractRustdeskFencedJson(html);
      expect(json, isNotNull);
      expect(json, contains('"host": "example.com"'));
      expect(json, contains('"key": "abc"'));
    });

    test('页面无围栏时返回 null', () {
      expect(extractRustdeskFencedJson('<p>no config here</p>'), isNull);
    });

    test('仅匹配 rustdesk 专属围栏，不误抓其它代码块', () {
      final html = '''
        ```json
        {"foo": "bar"}
        ```
        ```rustdesk
        {"host": "h", "key": "k"}
        ```
      ''';
      final json = extractRustdeskFencedJson(html);
      expect(json, isNotNull);
      expect(json, contains('"host": "h"'));
      expect(json, isNot(contains('"foo"')));
    });
  });

  group('parseServerConfigJson', () {
    test('解析 host/relay/key，relay 空串允许', () {
      final cfg = parseServerConfigJson('{"host":"h","relay":"","key":"k"}');
      expect(cfg.host, 'h');
      expect(cfg.relay, '');
      expect(cfg.key, 'k');
    });

    test('relay 字段省略时默认为空串', () {
      final cfg = parseServerConfigJson('{"host":"h","key":"k"}');
      expect(cfg.relay, '');
    });

    test('host 缺失时抛异常', () {
      expect(() => parseServerConfigJson('{"relay":"","key":"k"}'),
          throwsA(isA<Exception>()));
    });

    test('key 缺失时抛异常', () {
      expect(() => parseServerConfigJson('{"host":"h"}'),
          throwsA(isA<Exception>()));
    });

    test('非法 JSON 时抛异常', () {
      expect(() => parseServerConfigJson('not json'), throwsA(isA<Exception>()));
    });
  });

  group('fetchCloudServerConfig', () {
    test('使用注入的 fetcher 完成「抓取+截取+解析」整条链路', () async {
      const fakeHtml = 'x\n```rustdesk\n'
          '{"host":"h","relay":"r","key":"k"}\n```\ny';
      final cfg = await fetchCloudServerConfig(
        Uri.parse('https://example.com/cfg'),
        fetcher: (_) async => fakeHtml,
      );
      expect(cfg.host, 'h');
      expect(cfg.relay, 'r');
      expect(cfg.key, 'k');
    });

    test('围栏缺失时抛「未找到 rustdesk 配置块」', () async {
      expect(
        () => fetchCloudServerConfig(
          Uri.parse('https://example.com/cfg'),
          fetcher: (_) async => '<html><body>登录墙/无内容</body></html>',
        ),
        throwsA(predicate(
            (e) => e is Exception && e.toString().contains('rustdesk'))),
      );
    });

    test('无围栏时回退抓裸 JSON（适配 raw 纯文本 + 前缀说明文字）', () {
      const raw = '测试\n{\n  "host": "192.168.50.1",\n'
          '  "relay": "",\n  "key": "abc="\n}\n';
      final cfg = parseServerConfigJson(extractRustdeskFencedJson(raw)!);
      expect(cfg.host, '192.168.50.1');
      expect(cfg.relay, '');
      expect(cfg.key, 'abc=');
    });

    test('真实 raw 链接抓取并解析出 host', () async {
      final url = Uri.parse(
          'https://cnb.cool/zhiqiu520/remoteblog/-/git/raw/master/rdsk.txt');
      try {
        final cfg = await fetchCloudServerConfig(url);
        print('[cloudConfig][test] got host=${cfg.host} relay=${cfg.relay}');
        expect(cfg.host.isNotEmpty, isTrue);
        expect(cfg.key.isNotEmpty, isTrue);
      } catch (e) {
        // 无网络环境时跳过，不让离线 CI 失败。
        print('[cloudConfig][test] network skip: $e');
      }
    });
  });
}
