import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/chat/message_status.dart';

void main() {
  group('messageDeliveryStatus', () {
    test('not yet synced message is pending', () {
      expect(
        messageDeliveryStatus({'_pending': true, 'read': false}),
        MessageDeliveryStatus.pending,
      );
    });

    test('pending wins over read and delivered', () {
      expect(
        messageDeliveryStatus({
          '_pending': true,
          'read': true,
          'delivered_at': '2026-10-24T12:00:00Z',
        }),
        MessageDeliveryStatus.pending,
      );
    });

    test('stored but not delivered is sent', () {
      expect(
        messageDeliveryStatus({
          '_pending': false,
          'read': false,
          'delivered_at': null,
        }),
        MessageDeliveryStatus.sent,
      );
      expect(messageDeliveryStatus({}), MessageDeliveryStatus.sent);
    });

    test('delivered_at set means delivered', () {
      expect(
        messageDeliveryStatus({
          'read': false,
          'delivered_at': '2026-10-24T12:00:00Z',
        }),
        MessageDeliveryStatus.delivered,
      );
    });

    test(
      'read wins over delivered, also for old rows without delivered_at',
      () {
        expect(
          messageDeliveryStatus({
            'read': true,
            'delivered_at': '2026-10-24T12:00:00Z',
          }),
          MessageDeliveryStatus.read,
        );
        expect(
          messageDeliveryStatus({'read': true, 'delivered_at': null}),
          MessageDeliveryStatus.read,
        );
      },
    );
  });
}
