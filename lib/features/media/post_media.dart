import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';
import '../../image_compression.dart';

const String _photosBucket = 'photos';
const String _publicPhotosMarker = '/storage/v1/object/public/photos/';

/// Storage path of the small list version of a post image:
/// `user/123.jpg` → `user/123_thumb.jpg`.
String thumbnailPathFor(String fullPath) {
  final slash = fullPath.lastIndexOf('/');
  final dot = fullPath.lastIndexOf('.');
  final base = dot > slash ? fullPath.substring(0, dot) : fullPath;
  return '${base}_thumb.jpg';
}

/// Path inside the photos bucket for a stored post URL, or null.
String? photosStoragePathFromUrl(String? url) {
  final value = url?.trim() ?? '';
  final index = value.indexOf(_publicPhotosMarker);
  if (index < 0) return null;
  final path = value.substring(index + _publicPhotosMarker.length);
  return path.isEmpty ? null : Uri.decodeFull(path.split('?').first);
}

/// Every file of a post (image, its thumbnail, live clip), for deleting it.
List<String> postStoragePaths(Map<String, dynamic> photoRow) {
  final paths = <String>{};
  final imagePath = photosStoragePathFromUrl(photoRow['url']?.toString());
  if (imagePath != null) {
    paths
      ..add(imagePath)
      ..add(thumbnailPathFor(imagePath));
  }
  final thumbPath = photosStoragePathFromUrl(photoRow['thumb_url']?.toString());
  if (thumbPath != null) paths.add(thumbPath);
  final clipPath = (photoRow['live_photo_clip_path'] ?? '').toString().trim();
  if (clipPath.isNotEmpty) paths.add(clipPath);
  return paths.toList(growable: false);
}

/// Uploads a ~400 px copy of a post image for lists (leaderboard tiles,
/// profile grid; ~20–30 KB instead of ~120 KB). Returns its URL, or null if
/// anything fails – lists then show the full image.
Future<String?> uploadPostThumbnail({
  required SupabaseClient client,
  required String sourcePath,
  required String fullStoragePath,
}) async {
  try {
    final thumb = await compressImageForUpload(
      sourcePath,
      maxDimension: 400,
      quality: 70,
    );
    // The original came back: compression failed, a "thumbnail" would be
    // as big as the image itself.
    if (thumb.path == sourcePath) return null;
    final thumbPath = thumbnailPathFor(fullStoragePath);
    await client.storage.from(_photosBucket).upload(thumbPath, thumb);
    return client.storage.from(_photosBucket).getPublicUrl(thumbPath);
  } catch (e) {
    AppLogger.debug('Uploading post thumbnail failed: $e');
    return null;
  }
}

/// Image for small list tiles: the thumbnail when the post has one.
String listImageUrl(Map<String, dynamic> photoRow) {
  final thumb = (photoRow['thumb_url'] ?? '').toString().trim();
  return thumb.isNotEmpty ? thumb : (photoRow['url'] ?? '').toString();
}
