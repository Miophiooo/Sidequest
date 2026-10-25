# Push Notifications (Firebase FCM) - Setup

This project now covers all three parts required for reliable push delivery:
- device token registration in Flutter
- token and preference storage in Supabase
- backend dispatch for real remote pushes

## 1) Run the Supabase SQL files
Run these in the Supabase SQL Editor:
- `USER_DEVICE_TOKENS_TABLE.sql`
- `USER_NOTIFICATION_PREFS_TABLE.sql`
- `ADD_MENTION_NOTIFICATIONS.sql`
- `PUSH_NOTIFICATION_TRIGGERS.sql`
- `ENABLE_REALTIME.sql`

`PUSH_NOTIFICATION_TRIGGERS.sql` is the missing piece that actually triggers `send-push` for:
- `messages`
- `challenges`
- `photos`
- mention rows in `notifications`

`ENABLE_REALTIME.sql` is required for the in-app inbox and unread badges to update live from the `notifications` table.

Important:
- use the SQL triggers or Dashboard Webhooks, not both
- if you already created Supabase Database Webhooks for the same tables, remove or disable them to avoid duplicate pushes

## 2) Create the Firebase service account
Firebase Console -> Project settings -> Service accounts -> Generate new private key.

You need:
- `project_id`
- `client_email`
- `private_key`

## 3) Deploy the Supabase Edge Function
This repo includes the function here:
- `supabase/functions/send-push/index.ts`

Deploy it with JWT verification disabled:
```bash
supabase functions deploy send-push --no-verify-jwt
```

Set the required secrets:
```bash
supabase secrets set PUSH_SECRET=...
supabase secrets set FIREBASE_PROJECT_ID=...
supabase secrets set FIREBASE_CLIENT_EMAIL=...
supabase secrets set FIREBASE_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n'
supabase secrets set SERVICE_ROLE_KEY=...
```

Optional if your runtime does not inject `SUPABASE_URL`:
```bash
supabase secrets set SB_URL=https://<project-ref>.supabase.co
```

## 4) Create the Vault secrets used by SQL triggers
Run this once in the Supabase SQL Editor:
```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
select vault.create_secret('<PUSH_SECRET>', 'push_secret');
```

The SQL trigger file reads those secrets and posts to:
- `https://<project-ref>.supabase.co/functions/v1/send-push`

## 5) Test the function directly
Use:
- `scripts/test_send_push.ps1`

The script now calls the current Supabase Edge Function URL format:
- `https://<project-ref>.supabase.co/functions/v1/send-push`

## 6) iOS requirement
For iOS, remote notifications also require:
- Push Notifications capability
- Background Modes -> Remote notifications

The repo now includes the entitlements/plist changes, but you still need valid Apple provisioning for the target app id.
