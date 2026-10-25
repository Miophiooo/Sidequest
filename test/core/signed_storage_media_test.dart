import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/core/signed_storage_media.dart';

void main() {
  const base = 'https://cuvmtajkzgxroedmvfwu.supabase.co/storage/v1/object';

  group('SignedStorageUrls.privateObjectLocation', () {
    test('extracts bucket and path from a public photos URL', () {
      final location = SignedStorageUrls.privateObjectLocation(
        '$base/public/photos/abc-123/1700000000000.jpg',
      );
      expect(location, isNotNull);
      expect(location!.bucket, 'photos');
      expect(location.path, 'abc-123/1700000000000.jpg');
    });

    test('extracts nested live photo clip paths', () {
      final location = SignedStorageUrls.privateObjectLocation(
        '$base/public/photos/abc-123/live_photo/live_1700000000000.mp4',
      );
      expect(location, isNotNull);
      expect(location!.path, 'abc-123/live_photo/live_1700000000000.mp4');
    });

    test('ignores public buckets that stay public', () {
      expect(
        SignedStorageUrls.privateObjectLocation(
          '$base/public/profile_pictures/profile_abc.jpg',
        ),
        isNull,
      );
    });

    test('ignores already-signed URLs', () {
      expect(
        SignedStorageUrls.privateObjectLocation(
          '$base/sign/photos/abc-123/1700000000000.jpg?token=xyz',
        ),
        isNull,
      );
    });

    test('ignores non-storage URLs, empty and null input', () {
      expect(
        SignedStorageUrls.privateObjectLocation('https://example.com/a.jpg'),
        isNull,
      );
      expect(SignedStorageUrls.privateObjectLocation(''), isNull);
      expect(SignedStorageUrls.privateObjectLocation(null), isNull);
      expect(SignedStorageUrls.privateObjectLocation('not a url'), isNull);
    });

    test('ignores bucket-only URLs without an object path', () {
      expect(
        SignedStorageUrls.privateObjectLocation('$base/public/photos/'),
        isNull,
      );
    });
  });

  group('SignedStorageUrls.needsSigning', () {
    test('is true only for private-bucket public-style URLs', () {
      expect(
        SignedStorageUrls.needsSigning('$base/public/photos/u/f.jpg'),
        isTrue,
      );
      expect(
        SignedStorageUrls.needsSigning(
          '$base/public/profile_pictures/profile_u.jpg',
        ),
        isFalse,
      );
      expect(SignedStorageUrls.needsSigning(null), isFalse);
    });
  });
}
