import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_service.dart';

/// 获取网页文本内容。
///
/// 通过项目统一的 [HttpService] 发送请求（兼容代理 / Rust HTTP 通道），
/// 返回响应体字符串。非 2xx 状态码抛出 [Exception]。
Future<String> fetchWebContent(
  Uri url, {
  Map<String, String>? headers,
}) async {
  final resp =
      await HttpService().sendRequest(url, HttpMethod.get, headers: headers);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('HTTP ${resp.statusCode}: ${url.toString()}');
  }
  return resp.body;
}

/// 获取网页二进制内容，返回原始字节。
Future<Uint8List> fetchWebBytes(
  Uri url, {
  Map<String, String>? headers,
}) async {
  final resp =
      await HttpService().sendRequest(url, HttpMethod.get, headers: headers);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('HTTP ${resp.statusCode}: ${url.toString()}');
  }
  return resp.bodyBytes;
}

/// 下载文件到本地，支持进度回调。
///
/// [savePath] 为目标文件路径（父目录需存在或可创建）。
/// [onProgress] 回调参数为已接收字节数与总字节数（服务器未返回 Content-Length 时 total 为 null）。
/// 非 2xx 状态码抛 [Exception]，调用方负责清理已写入的临时文件。
Future<File> downloadFile(
  Uri url,
  String savePath, {
  Map<String, String>? headers,
  void Function(int received, int? total)? onProgress,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final request = http.Request('GET', url);
    if (headers != null) request.headers.addAll(headers);
    final response = await c.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${url.toString()}');
    }
    final total = response.contentLength;
    final file = File(savePath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    int received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return file;
  } finally {
    if (client == null) c.close();
  }
}

/// 从网页 / 纯文本内容中抽取 rustdesk 配置 JSON。
///
/// 截取策略（按优先级）：
/// 1. 优先匹配 ```rustdesk 围栏代码块（精确，避免误抓页面其它代码块）；
/// 2. 找不到围栏时，回退为抓取文本中第一个花括号 `{...}` JSON 段
///    （适配 raw 纯文本文件，允许 JSON 前后有其它说明文字）。
/// 都找不到时返回 null。
String? extractRustdeskFencedJson(String html) {
  final fence = RegExp(r'```rustdesk\s*?\n(.*?)```', dotAll: true);
  final m = fence.firstMatch(html);
  if (m != null) return m.group(1)?.trim();
  // 回退：抓第一个 { 到最后一个 } 之间的内容作为裸 JSON。
  final start = html.indexOf('{');
  final end = html.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return html.substring(start, end + 1).trim();
  }
  return null;
}

/// 从 ```rustdesk 围栏 JSON 文本解析出服务器配置。
///
/// 仅解析 [host] / [relay] / [key] 三个字段（无 api）。
/// [host] 或 [key] 缺失时抛出 [Exception]；
/// [relay] 为空或缺失时返回空串，由调用方决定是否填充。
({String host, String relay, String key}) parseServerConfigJson(
    String jsonText) {
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(jsonText);
  } catch (e) {
    throw Exception('配置 JSON 解析失败: $e');
  }
  final host = (json['host'] as String? ?? '').trim();
  final key = (json['key'] as String? ?? '').trim();
  final relay = (json['relay'] as String? ?? '').trim();
  if (host.isEmpty || key.isEmpty) {
    throw Exception('云端配置缺少 host 或 key');
  }
  return (host: host, relay: relay, key: key);
}

/// 用普通 [http] 请求抓取网页文本，避免依赖 Rust FFI HTTP 通道
/// （[HttpService] 在未初始化时会抛 LateInitializationError）。
Future<String> _fetchPlainText(Uri url) async {
  final resp = await http.get(url);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('HTTP ${resp.statusCode}: $url');
  }
  return resp.body;
}

/// 抓取云端服务器配置文档，截取其中的 rustdesk 配置 JSON 并解析。
///
/// [fetcher] 可注入，默认走 [_fetchPlainText]（普通 http，便于测试且不依赖 FFI）。
/// [host] 或 [key] 缺失时抛出 [Exception]；
/// [relay] 为空或缺失时返回空串，由调用方决定是否填充。
Future<({String host, String relay, String key})> fetchCloudServerConfig(
    Uri url,
    {Future<String> Function(Uri)? fetcher}) async {
  print('[cloudConfig] fetching $url');
  final html = await (fetcher ?? _fetchPlainText)(url);
  print('[cloudConfig] html length=${html.length}, '
      'hasRustdeskFence=${extractRustdeskFencedJson(html) != null}');
  final jsonText = extractRustdeskFencedJson(html);
  if (jsonText == null) {
    print('[cloudConfig] no rustdesk fence found in page');
    throw Exception('未在页面中找到 rustdesk 配置块');
  }
  print('[cloudConfig] extracted json: $jsonText');
  return parseServerConfigJson(jsonText);
}
