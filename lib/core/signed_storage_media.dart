import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Storage buckets that are private and therefore require signed URLs for
/// downloads. The database keeps storing stable public-style URLs
/// (`.../storage/v1/object/public/<bucket>/<path>`); the swap to a signed URL
/// happens lazily at fetch time so cache keys never change.
const Set<String> kSideQuestPrivateBuckets = {'photos'};

class _SignedEntry {
  final String url;
  final DateTime refreshAfter;

  const _SignedEntry(this.url, this.refreshAfter);

  bool get isFresh => DateTime.now().isBefore(refreshAfter);
}

class SignedStorageUrls {
  SignedStorageUrls._();

  static const Duration _ttl = Duration(hours: 12);

  /// Re-sign well before the token expires so loads started near the
  /// deadline (e.g. a video that buffers slowly) don't race expiry.
  static const Duration _refreshMargin = Duration(minutes: 30);

  static final Map<String, _SignedEntry> _cache = {};
  static final Map<String, Future<String?>> _inflight = {};

  /// Returns the (bucket, path) of [url] when it points at an object in one
  /// of [kSideQuestPrivateBuckets], otherwise null. Already-signed URLs
  /// (`/object/sign/...`) and public-bucket URLs are left alone.
  static ({String bucket, String path})? privateObjectLocation(String? url) {
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    final segments = uri.pathSegments;
    final objectIdx = segments.indexOf('object');
    if (objectIdx < 0 || objectIdx + 3 > segments.length - 1) return null;
    if (segments[objectIdx + 1] != 'public') return null;

    final bucket = segments[objectIdx + 2];
    if (!kSideQuestPrivateBuckets.contains(bucket)) return null;

    final path = segments.sublist(objectIdx + 3).join('/');
    if (path.isEmpty) return null;
    return (bucket: bucket, path: path);
  }

  static bool needsSigning(String? url) => privateObjectLocation(url) != null;

  /// Swaps a stored public-style URL for a short-lived signed URL.
  ///
  /// Falls back to the original URL when signing fails (offline, signed-out,
  /// object deleted, no permission) so callers keep their existing
  /// error-widget behavior.
  static Future<String> resolve(String url) async {
    final location = privateObjectLocation(url);
    if (location == null) return url;

    final cached = _cache[url];
    if (cached != null && cached.isFresh) return cached.url;

    final pending = _inflight[url] ??= _sign(url, location);
    final signed = await pending;
    return signed ?? url;
  }

  static Future<String?> _sign(
    String cacheKey,
    ({String bucket, String path}) location,
  ) async {
    try {
      final signed = await Supabase.instance.client.storage
          .from(location.bucket)
          .createSignedUrl(location.path, _ttl.inSeconds);
      _cache[cacheKey] = _SignedEntry(
        signed,
        DateTime.now().add(_ttl - _refreshMargin),
      );
      return signed;
    } catch (_) {
      return null;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  /// Drops cached tokens, e.g. on sign-out.
  static void clear() {
    _cache.clear();
  }
}

class _SignedUrlFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    return super.get(await SignedStorageUrls.resolve(url), headers: headers);
  }
}

/// Disk cache for private-bucket media. Cache entries are keyed by the
/// stored public-style URL, so they survive signed-token rotation and
/// images that are already on disk never trigger a signing round-trip.
class SideQuestSignedMediaCacheManager extends CacheManager {
  static const String _cacheKey = 'sqSignedMediaCache';

  static final SideQuestSignedMediaCacheManager instance =
      SideQuestSignedMediaCacheManager._();

  SideQuestSignedMediaCacheManager._()
    : super(Config(_cacheKey, fileService: _SignedUrlFileService()));
}

/// Cache manager for [url]: private-bucket media goes through the signing
/// cache manager, everything else (avatars, external images) keeps the
/// default cache so existing disk entries stay valid.
BaseCacheManager? sideQuestCacheManagerFor(String? url) {
  return SignedStorageUrls.needsSigning(url)
      ? SideQuestSignedMediaCacheManager.instance
      : null;
}
