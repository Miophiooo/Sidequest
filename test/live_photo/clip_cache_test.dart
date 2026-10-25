// package:file comes with flutter_cache_manager (its File type is part of
// the BaseCacheManager API).
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:file/file.dart' as file_pkg;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/live_photo/live_photo_feed_media.dart';
import 'package:video_player/video_player.dart';

class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(this.file, {this.fail = false});

  final file_pkg.File file;
  final bool fail;
  final List<String> requested = [];

  @override
  Future<file_pkg.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    requested.add(url);
    if (fail) throw const SocketException('offline');
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const clipUrl =
      'https://example.supabase.co/storage/v1/object/public/other/u/live.mp4';

  test('a posted clip plays from the cache file', () async {
    final dir = await Directory.systemTemp.createTemp('sq_clip');
    addTearDown(() => dir.delete(recursive: true));
    final cached = const LocalFileSystem().file('${dir.path}/clip.mp4')
      ..writeAsBytesSync([0, 1, 2]);
    final cache = _FakeCacheManager(cached);

    final controller = await remoteLiveClipController(
      clipUrl,
      cacheManager: cache,
    );

    expect(cache.requested, [clipUrl]);
    expect(controller.dataSourceType, DataSourceType.file);
    expect(controller.dataSource, contains('clip.mp4'));
  });

  test('falls back to streaming when caching fails', () async {
    final cache = _FakeCacheManager(
      const LocalFileSystem().file('/nonexistent'),
      fail: true,
    );

    final controller = await remoteLiveClipController(
      clipUrl,
      cacheManager: cache,
    );

    expect(controller.dataSourceType, DataSourceType.network);
    expect(controller.dataSource, clipUrl);
  });
}
