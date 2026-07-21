import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
