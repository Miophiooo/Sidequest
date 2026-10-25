import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/media/post_media.dart';

void main() {
  const base = 'https://abc.supabase.co/storage/v1/object/public/photos/';

  test('thumbnail sits next to the image', () {
    expect(thumbnailPathFor('u1/123.jpg'), 'u1/123_thumb.jpg');
    expect(
      thumbnailPathFor('u1/live_photo/live_9.jpg'),
      'u1/live_photo/live_9_thumb.jpg',
    );
    expect(thumbnailPathFor('u1/noext'), 'u1/noext_thumb.jpg');
  });

  test('storage path from a stored post URL', () {
    expect(photosStoragePathFromUrl('${base}u1/123.jpg'), 'u1/123.jpg');
    expect(photosStoragePathFromUrl('${base}u1/123.jpg?v=2'), 'u1/123.jpg');
    expect(photosStoragePathFromUrl('https://other.example/x.jpg'), isNull);
    expect(photosStoragePathFromUrl(null), isNull);
  });

  test('deleting a live post removes image, thumbnail and clip', () {
    final paths = postStoragePaths({
      'url': '${base}u1/live_photo/live_9.jpg',
      'thumb_url': '${base}u1/live_photo/live_9_thumb.jpg',
      'live_photo_clip_path': 'u1/live_photo/live_9.mp4',
    });
    expect(
      paths,
      unorderedEquals([
        'u1/live_photo/live_9.jpg',
        'u1/live_photo/live_9_thumb.jpg',
        'u1/live_photo/live_9.mp4',
      ]),
    );
  });

  test('lists use the thumbnail when there is one', () {
    expect(
      listImageUrl({'url': '${base}a.jpg', 'thumb_url': '${base}a_thumb.jpg'}),
      '${base}a_thumb.jpg',
    );
    expect(
      listImageUrl({'url': '${base}a.jpg', 'thumb_url': null}),
      '${base}a.jpg',
    );
  });
}
