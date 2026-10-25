import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';
import '../../shared.dart';

/// WhatsApp-style state of an own chat message.
enum MessageDeliveryStatus { pending, sent, delivered, read }

/// Read wins over delivered; a local, not yet synced message is pending.
MessageDeliveryStatus messageDeliveryStatus(Map<String, dynamic> message) {
  if (message['_pending'] == true) return MessageDeliveryStatus.pending;
  if (message['read'] == true) return MessageDeliveryStatus.read;
  if (message['delivered_at'] != null) return MessageDeliveryStatus.delivered;
  return MessageDeliveryStatus.sent;
}

const Color _readTickColor = Color(0xFF1565C0);

/// 🕓 / ✓ / ✓✓ / blue ✓✓ next to the time of an own message.
class MessageStatusTicks extends StatelessWidget {
  const MessageStatusTicks({super.key, required this.status});

  final MessageDeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final muted = Colors.black.withValues(alpha: 0.55);
    final (icon, color, label) = switch (status) {
      MessageDeliveryStatus.pending => (
        Icons.schedule_rounded,
        muted,
        t('Wird gesendet', 'Sending'),
      ),
      MessageDeliveryStatus.sent => (
        Icons.done_rounded,
        muted,
        t('Gesendet', 'Sent'),
      ),
      MessageDeliveryStatus.delivered => (
        Icons.done_all_rounded,
        muted,
        t('Zugestellt', 'Delivered'),
      ),
      MessageDeliveryStatus.read => (
        Icons.done_all_rounded,
        _readTickColor,
        t('Gelesen', 'Read'),
      ),
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 14, color: color),
    );
  }
}

bool _markingDelivered = false;
bool _markAgain = false;

/// Tells the server that this device has received all messages sent to the
/// signed-in user (second grey tick for the sender). Calls made while one is
/// running are merged into a single follow-up call.
Future<void> markMessagesDelivered() async {
  final client = Supabase.instance.client;
  if (client.auth.currentUser == null) return;
  if (_markingDelivered) {
    _markAgain = true;
    return;
  }
  _markingDelivered = true;
  try {
    do {
      _markAgain = false;
      await client.rpc('mark_messages_delivered');
    } while (_markAgain);
  } catch (e) {
    AppLogger.debug('mark_messages_delivered failed: $e');
  } finally {
    _markingDelivered = false;
    _markAgain = false;
  }
}
