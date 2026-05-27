import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/controllers.dart';

/// 规范化图片 URL：null/空返回 null，其余原样保留
String? normalizeImageUrl(String? url) {
  if (url == null || url.trim().isEmpty) return null;
  return url.trim();
}

const _kAgentPort = 50571;

/// 通过 PC Agent 代理加载网易云 CDN 封面图片
/// 手机端可能无法直连网易云 CDN（DNS/防火墙/系统限制），
/// 因此通过局域网内的 PC Agent 做 HTTP 代理
class CoverImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final AlignmentGeometry alignment;
  final Widget? placeholder;
  final Widget? errorWidget;

  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.cacheHeight,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  static final Map<String, Uint8List> _memoryCache = <String, Uint8List>{};
  static final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  static const int _maxCacheEntries = 5;

  // 共享 HttpClient：复用 TCP/TLS 连接，避免每张封面新建 socket 的开销。
  // 长 idleTimeout 让 HTTP keep-alive 命中；应用生命周期内不主动 close。
  static final HttpClient _sharedClient =
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..idleTimeout = const Duration(seconds: 60);

  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;
  bool _initialLoadDone = false;
  String? _observedProxyHost;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final proxyHost = _getProxyHost(listen: true);
    // Provider.of 需要在 didChangeDependencies 中调用，initState 时 widget 未完全挂载
    if (!_initialLoadDone) {
      _initialLoadDone = true;
      _observedProxyHost = proxyHost;
      final cached = _memoryCache[widget.url];
      if (cached != null) {
        _bytes = cached;
        _loading = false;
        _error = false;
      }
      _load(proxyHost: proxyHost);
      return;
    }

    if (_observedProxyHost != proxyHost) {
      _observedProxyHost = proxyHost;
      if (proxyHost != null &&
          proxyHost.isNotEmpty &&
          (_bytes == null || _error)) {
        _load(proxyHost: proxyHost);
      }
    }
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _load();
    }
  }

  String? _getProxyHost({bool listen = false}) {
    try {
      final conn = Provider.of<ConnectionController>(context, listen: listen);
      return conn.connectedHost;
    } catch (_) {
      return null;
    }
  }

  Future<void> _load({String? proxyHost}) async {
    final url = widget.url;
    final cached = _memoryCache[url];
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _bytes = cached;
        _loading = false;
        _error = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = false;
      // 保留旧图直到新图加载完成，避免折叠/全屏切换瞬时闪烁
    });

    final resolvedProxyHost = proxyHost ?? _getProxyHost();
    if (resolvedProxyHost == null || resolvedProxyHost.isEmpty) {
      return;
    }

    // 代理 host 参与 key，避免“未连接时的空请求”和“已连接后的真实代理请求”
    // 被误判为同一个 in-flight 任务。
    final requestKey = '$resolvedProxyHost|$url';
    final future = _inFlight.putIfAbsent(
      requestKey,
      () => _fetchViaProxy(resolvedProxyHost),
    );

    final bytes = await future;

    _inFlight.remove(requestKey);
    // 不论 widget 是否还挂着都写缓存。折叠模式下切歌会让 musicState.coverImgUrl
    // 先穿过 null（_trackChangeResetState），上层 _SectionCoverBackdrop 早一帧返回
    // SizedBox.shrink() unmount 掉这个 State，原来"if (!mounted) return"会丢掉刚抓到的
    // bytes —— 紧接着新 CoverImage 挂回来再 _load 一次，可能因竞态拿不到结果，
    // 直到用户切全屏让 widget tree 强重建才恢复。先入缓存再 setState 即可消除。
    if (bytes != null) {
      _memoryCache[url] = bytes;
      _trimCacheIfNeeded();
    }
    if (!mounted) return;
    // 中途 widget.url 被改成别的 URL 就别用旧 bytes 覆盖（didUpdateWidget 已经
    // 触发了新 URL 的 _load，让它去 setState）。
    if (widget.url != url) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
      _error = bytes == null;
    });
  }

  void _trimCacheIfNeeded() {
    while (_memoryCache.length > _maxCacheEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
  }

  /// 通过 PC Agent 代理获取图片
  Future<Uint8List?> _fetchViaProxy(String host) async {
    final proxyUrl =
        'http://${_hostWithPort(host)}/cover?url=${Uri.encodeComponent(widget.url)}';
    return _doFetch(proxyUrl);
  }

  String _hostWithPort(String host) {
    // host 可能已经包含端口
    if (host.contains(':')) return host;
    return '$host:$_kAgentPort';
  }

  Future<Uint8List?> _doFetch(String url) async {
    try {
      var request = await _sharedClient.getUrl(Uri.parse(url));
      request.headers.set('Referer', 'https://music.126.net/');

      var response = await request.close();

      // 手动跟随重定向，保留 headers。共享 HttpClient 下必须 drain 旧 response，
      // 否则该 socket 不会回到 keep-alive 池。
      var redirectCount = 0;
      while (response.isRedirect && redirectCount < 5) {
        final location = response.headers.value('location');
        await response.drain<void>();
        if (location == null) break;
        request = await _sharedClient.getUrl(Uri.parse(location));
        request.headers.set('Referer', 'https://music.126.net/');
        response = await request.close();
        redirectCount++;
      }

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }

      return consolidateHttpClientResponseBytes(response);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _bytes == null) {
      return SizedBox.expand(
        child:
            widget.placeholder ??
            const DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFF0A1628)),
            ),
      );
    }

    if (_error || _bytes == null) {
      return SizedBox.expand(
        child:
            widget.errorWidget ??
            const Center(
              child: Icon(
                Icons.music_note_rounded,
                color: Color(0x30FFFFFF),
                size: 36,
              ),
            ),
      );
    }

    return Image.memory(
      _bytes!,
      fit: widget.fit,
      alignment: widget.alignment,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      gaplessPlayback: true,
    );
  }
}
