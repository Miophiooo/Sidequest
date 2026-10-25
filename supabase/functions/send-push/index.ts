// Supabase Edge Function: send-push
// Sends Firebase Cloud Messaging (FCM) pushes to tokens stored in `user_device_tokens`.
//
// Auth:
// - Caller must send header x-push-secret with the Vault secret `push_secret`
//   (read via public.edge_secret).
//
// Required env:
// - SUPABASE_URL
// - SUPABASE_SERVICE_ROLE_KEY
// - FIREBASE_PROJECT_ID
// - FIREBASE_CLIENT_EMAIL
// - FIREBASE_PRIVATE_KEY  (use \n for newlines)
//
// Payload:
// {
//   type: 'messages' | 'friends_posts' | 'challenge_start' | 'challenge_ending' | 'challenged' | 'mention'
//   recipient_user_ids: string[]
//   title: string
//   body: string
//   data?: Record<string, string>
// }

// Deno provides the `Deno` global at runtime, but VS Code/tsserver may not know about it.
// We declare it to keep type-checking happy without affecting runtime.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const Deno: any;

// Supabase Edge Functions resolve remote imports at runtime (Deno).
// tsserver/tsc can't resolve `https:` module specifiers in a typical Node setup.
// @ts-ignore
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type PushType =
  | "messages"
  | "friends_posts"
  | "challenge_start"
  | "challenge_ending"
  | "challenged"
  | "mention";

type Payload = {
  type: PushType;
  recipient_user_ids: string[];
  title: string;
  body: string;
  data?: Record<string, string>;
};

type SupabaseWebhookPayload = {
  type?: string; // INSERT | UPDATE | DELETE
  table?: string;
  schema?: string;
  record?: Record<string, unknown> | null;
  old_record?: Record<string, unknown> | null;
  // Some webhook variants may use `new`/`old`
  new?: Record<string, unknown> | null;
  old?: Record<string, unknown> | null;
};

function looksLikeMojibake(value: string): boolean {
  return (
    value.includes("Ã") ||
    value.includes("Â") ||
    value.includes("â€™") ||
    value.includes("â€œ") ||
    value.includes("â€") ||
    value.includes("â€“") ||
    value.includes("â€”")
  );
}

function repairMojibakeText(value: string): string {
  let current = value;
  const decoder = new TextDecoder("utf-8", { fatal: false });

  for (let i = 0; i < 3; i++) {
    if (!looksLikeMojibake(current)) break;

    const bytes = new Uint8Array(current.length);
    let valid = true;
    for (let j = 0; j < current.length; j++) {
      const code = current.charCodeAt(j);
      if (code > 0xff) {
        valid = false;
        break;
      }
      bytes[j] = code;
    }

    if (!valid) break;
    const repaired = decoder.decode(bytes);
    if (repaired === current) break;
    current = repaired;
  }

  return current;
}

function normalizePayloadData(
  type: PushType,
  data?: Record<string, string>,
): Record<string, string> {
  const next: Record<string, string> = {};
  for (const [key, value] of Object.entries(data ?? {})) {
    next[key] = repairMojibakeText(String(value));
  }

  next.kind ??=
    type === "friends_posts"
      ? "friends_post"
      : type === "challenge_start" || type === "challenge_ending"
        ? type
        : type === "messages"
          ? "message"
          : type;

  if (!next.target_tab) {
    if (type === "messages" || type === "challenged") {
      next.target_tab = "1";
    } else if (type === "challenge_start" || type === "challenge_ending") {
      next.target_tab = "0";
    } else if (type === "friends_posts") {
      next.target_tab = next.is_public === "true" ? "2" : "0";
    } else if (type === "mention") {
      next.target_tab = next.photo_id ? "2" : "1";
    }
  }

  return next;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });
}

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function getSupabaseUrl(): string {
  // Supabase Edge Functions inject SUPABASE_URL automatically.
  // Supabase CLI blocks setting secrets that start with SUPABASE_.
  return Deno.env.get("SUPABASE_URL") ?? Deno.env.get("SB_URL") ?? requireEnv("SB_URL");
}

function getServiceRoleKey(): string {
  // Prefer injected env if present, otherwise use a custom secret name.
  return (
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SERVICE_ROLE_KEY") ??
    Deno.env.get("SB_SERVICE_ROLE_KEY") ??
    requireEnv("SERVICE_ROLE_KEY")
  );
}

async function getAccessToken(): Promise<string> {
  const clientEmail = requireEnv("FIREBASE_CLIENT_EMAIL");
  const privateKey = requireEnv("FIREBASE_PRIVATE_KEY").replace(/\\n/g, "\n");

  const header = {
    alg: "RS256",
    typ: "JWT",
  };

  const now = Math.floor(Date.now() / 1000);
  const claimSet = {
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 60 * 50,
  };

  const enc = new TextEncoder();
  const b64url = (input: Uint8Array) =>
    btoa(String.fromCharCode(...input))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");

  const headerPart = b64url(enc.encode(JSON.stringify(header)));
  const payloadPart = b64url(enc.encode(JSON.stringify(claimSet)));
  const unsigned = `${headerPart}.${payloadPart}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(unsigned)),
  );
  const jwt = `${unsigned}.${b64url(signature)}`;

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!tokenRes.ok) {
    const text = await tokenRes.text();
    throw new Error(`OAuth token error: ${tokenRes.status} ${text}`);
  }

  const json = (await tokenRes.json()) as { access_token: string };
  return json.access_token;
}

function pemToPkcs8(pem: string): ArrayBuffer {
  // Remove header/footer and decode base64
  const lines = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .trim()
    .split(/\r?\n/)
    .join("");
  const binary = atob(lines);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function prefColumnForType(t: PushType): string | null {
  // Table `user_notification_prefs` uses these column names.
  if (t === "mention") return null;
  return t;
}

function asString(v: unknown): string | null {
  return typeof v === "string" && v.trim().length > 0 ? v : null;
}

function buildPayloadFromSupabaseWebhook(body: SupabaseWebhookPayload): Payload | null {
  const table = asString(body.table);
  if (!table) return null;

  const eventType = asString(body.type) ?? "";
  if (eventType && eventType !== "INSERT") {
    // For now, only push on INSERT.
    return null;
  }

  const record = (body.record ?? body.new ?? null) as Record<string, unknown> | null;
  if (!record) return null;

  if (table === "messages") {
    const receiverId = asString(record["receiver_id"]);
    const senderId = asString(record["sender_id"]);
    const messageText = asString(record["message"]) ?? "New message";
    const messageId = asString(record["id"]);

    if (!receiverId) return null;

    // Keep notification short.
    const trimmed = messageText.length > 140 ? `${messageText.slice(0, 137)}...` : messageText;

    return {
      type: "messages",
      recipient_user_ids: [receiverId],
      title: "SideQuest",
      body: trimmed,
      data: {
        kind: "message",
        target_tab: "1",
        ...(senderId ? { sender_id: senderId } : {}),
        ...(messageId ? { message_id: messageId } : {}),
      },
    };
  }

  if (table === "challenges") {
    const challengedId = asString(record["challenged_id"]);
    const challengerId = asString(record["challenger_id"]);
    const challengeId = asString(record["id"]);
    if (!challengedId) return null;

    return {
      type: "challenged",
      recipient_user_ids: [challengedId],
      title: "SideQuest",
      body: "Du wurdest herausgefordert!",
      data: {
        kind: "challenged",
        target_tab: "1",
        ...(challengerId ? { challenger_id: challengerId } : {}),
        ...(challengeId ? { challenge_id: challengeId } : {}),
      },
    };
  }

  if (table === "photos") {
    const posterId = asString(record["user_id"]);
    const photoId = asString(record["id"]);
    const url = asString(record["url"]);
    const isPublic = record["is_public"] === true;

    if (!posterId) return null;

    return {
      type: "friends_posts",
      recipient_user_ids: [posterId], // placeholder; expanded later after we have a Supabase client
      title: "SideQuest",
      body: "Neues Foto von einem Freund!",
      data: {
        kind: "friends_post",
        target_tab: isPublic ? "2" : "0",
        ...(posterId ? { poster_id: posterId } : {}),
        ...(photoId ? { photo_id: photoId } : {}),
        ...(url ? { url } : {}),
        is_public: String(isPublic),
      },
    };
  }

  if (table === "notifications") {
    const recipientId = asString(record["user_id"]);
    const notificationType = asString(record["type"]);
    const message = asString(record["message"]);
    const photoId = asString(record["photo_id"]);
    const commentId = asString(record["comment_id"]);

    if (!recipientId || notificationType !== "mention" || !message) {
      return null;
    }

    return {
      type: "mention",
      recipient_user_ids: [recipientId],
      title: "SideQuest",
      body: message,
      data: {
        kind: "mention",
        target_tab: photoId ? "2" : "1",
        ...(photoId ? { photo_id: photoId } : {}),
        ...(commentId ? { comment_id: commentId } : {}),
      },
    };
  }

  // Optional: add photos support later (needs friend lookup).
  return null;
}

// Shared secrets live in Supabase Vault and are read through
// public.edge_secret() (service role only), so the database (cron, triggers)
// and the functions always use the same values; rotating is one SQL call.
const SECRET_TTL_MS = 60_000;
const secretCache = new Map<string, { value: string; loadedAt: number }>();

async function loadSecret(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  supabase: any,
  name: string,
  fresh = false,
): Promise<string> {
  const cached = secretCache.get(name);
  if (!fresh && cached && Date.now() - cached.loadedAt < SECRET_TTL_MS) {
    return cached.value;
  }
  const { data, error } = await supabase.rpc("edge_secret", { p_name: name });
  if (error || typeof data !== "string" || data.length === 0) {
    throw new Error(`Vault secret ${name} unavailable`);
  }
  secretCache.set(name, { value: data, loadedAt: Date.now() });
  return data;
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// On a mismatch the vault is re-read once (at most every 10 s) so a fresh
// rotation is picked up without waiting for the cache to expire.
async function secretMatches(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  supabase: any,
  name: string,
  got: string,
): Promise<boolean> {
  if (!got) return false;
  if (timingSafeEqual(got, await loadSecret(supabase, name))) return true;
  const cached = secretCache.get(name);
  if (cached && Date.now() - cached.loadedAt < 10_000) return false;
  return timingSafeEqual(got, await loadSecret(supabase, name, true));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return jsonResponse({ error: "POST only" }, 405);

  const supabase = createClient(getSupabaseUrl(), getServiceRoleKey(), {
    auth: { persistSession: false },
  });

  let authorized = false;
  try {
    authorized = await secretMatches(
      supabase,
      "push_secret",
      req.headers.get("x-push-secret") ?? "",
    );
  } catch (_) {
    return jsonResponse({ error: "server misconfigured" }, 500);
  }
  if (!authorized) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  let payload: Payload;
  try {
    const raw = (await req.json()) as unknown;
    // Accept both our custom payload and Supabase Database Webhook payload.
    const maybePayload = raw as Partial<Payload>;
    if (
      maybePayload &&
      typeof maybePayload.type === "string" &&
      Array.isArray(maybePayload.recipient_user_ids) &&
      typeof maybePayload.title === "string" &&
      typeof maybePayload.body === "string"
    ) {
      payload = maybePayload as Payload;
    } else {
      const fromWebhook = buildPayloadFromSupabaseWebhook(raw as SupabaseWebhookPayload);
      if (!fromWebhook) return jsonResponse({ ok: true, sent: 0, reason: "ignored" }, 200);
      payload = fromWebhook;
    }
  } catch {
    return jsonResponse({ error: "invalid json" }, 400);
  }

  if (
    !payload ||
    !payload.type ||
    !Array.isArray(payload.recipient_user_ids) ||
    payload.recipient_user_ids.length === 0 ||
    typeof payload.title !== "string" ||
    typeof payload.body !== "string"
  ) {
    return jsonResponse({ error: "invalid payload" }, 400);
  }

  payload = {
    ...payload,
    title: repairMojibakeText(payload.title),
    body: repairMojibakeText(payload.body),
    data: normalizePayloadData(payload.type, payload.data),
  };

  if (payload.type === "mention" && payload.data?.photo_id) {
    try {
      const photoId = payload.data.photo_id;
      const { data: photoRow } = await supabase
        .from("photos")
        .select("id, is_public")
        .eq("id", photoId)
        .maybeSingle();

      if (photoRow && typeof photoRow === "object") {
        const isPublic = (photoRow as Record<string, unknown>)["is_public"] === true;
        payload = {
          ...payload,
          data: {
            ...(payload.data ?? {}),
            target_tab: isPublic ? "2" : "0",
            is_public: String(isPublic),
          },
        };
      }
    } catch (_) {
      // Keep the existing payload if photo lookup fails.
    }
  }

  // If this was a photos webhook, expand recipients to the poster's accepted friends.
  if (payload.type === "friends_posts" && payload.data?.poster_id) {
    const posterId = payload.data.poster_id;
    const { data: friendsRows } = await supabase
      .from("friends")
      .select("user_id, friend_id")
      .eq("status", "accepted")
      .or(`user_id.eq.${posterId},friend_id.eq.${posterId}`);

    const friendIds = new Set<string>();
    for (const row of (friendsRows ?? []) as Array<Record<string, unknown>>) {
      const u = asString(row["user_id"]);
      const f = asString(row["friend_id"]);
      if (!u || !f) continue;
      const other = u === posterId ? f : u;
      if (other && other !== posterId) friendIds.add(other);
    }

    payload = {
      ...payload,
      recipient_user_ids: [...friendIds],
    };

    if (payload.recipient_user_ids.length === 0) {
      return jsonResponse({ ok: true, sent: 0, reason: "no friends" }, 200);
    }
  }

  // Filter recipients by server-side preferences
  const prefColumn = prefColumnForType(payload.type);
  let prefsRows: Array<Record<string, unknown>> | null = null;
  let prefsErr: { message: string } | null = null;

  if (prefColumn) {
    const prefsResult = await supabase
      .from("user_notification_prefs")
      .select(`user_id, ${prefColumn}`)
      .in("user_id", payload.recipient_user_ids);
    prefsRows = prefsResult.data as Array<Record<string, unknown>> | null;
    prefsErr = prefsResult.error;
  }

  if (prefsErr) {
    // If prefs table isn't deployed yet, fail safe by still sending.
    // (Otherwise pushes would "randomly" stop.)
  }

  const allowedUserIds = new Set<string>();
  if (!prefColumn) {
    for (const id of payload.recipient_user_ids) allowedUserIds.add(id);
  } else if (prefsRows && Array.isArray(prefsRows) && prefsRows.length > 0) {
    for (const row of prefsRows as Array<Record<string, unknown>>) {
      const id = row["user_id"];
      const enabled = row[prefColumn];
      if (typeof id === "string" && enabled !== false) {
        allowedUserIds.add(id);
      }
    }
  } else {
    // No prefs row yet => default true
    for (const id of payload.recipient_user_ids) allowedUserIds.add(id);
  }

  const filteredIds = [...allowedUserIds];
  if (filteredIds.length === 0) {
    return jsonResponse({ ok: true, sent: 0, filtered: payload.recipient_user_ids.length });
  }

  const { data: tokenRows, error: tokenErr } = await supabase
    .from("user_device_tokens")
    .select("user_id, token")
    .in("user_id", filteredIds);

  if (tokenErr) {
    return jsonResponse({ error: `token query failed: ${tokenErr.message}` }, 500);
  }

  const tokens: string[] = [];
  for (const row of (tokenRows ?? []) as Array<{ token?: string }>) {
    if (row.token && typeof row.token === "string" && row.token.length > 0) {
      tokens.push(row.token);
    }
  }

  if (tokens.length === 0) {
    return jsonResponse({ ok: true, sent: 0, reason: "no tokens" });
  }

  const projectId = requireEnv("FIREBASE_PROJECT_ID");
  const accessToken = await getAccessToken();

  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  const sendOne = async (token: string) => {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: {
            title: payload.title,
            body: payload.body,
          },
          data: payload.data ?? {},
          android: {
            priority: "HIGH",
            notification: {
              channel_id: "sidequest_general",
              sound: "default",
            },
          },
          apns: {
            headers: {
              "apns-priority": "10",
            },
            payload: {
              aps: {
                sound: "default",
                "content-available": 1,
                "mutable-content": 1,
              },
            },
          },
        },
      }),
    });

    if (res.ok) return { ok: true };

    const text = await res.text();
    // Best-effort cleanup for invalid tokens.
    if (text.includes("UNREGISTERED") || text.includes("NotRegistered")) {
      try {
        await supabase.from("user_device_tokens").delete().eq("token", token);
      } catch (_) {
        // ignore
      }
    }
    return { ok: false, status: res.status, body: text };
  };

  // Limit concurrency a bit
  const concurrency = 10;
  let sent = 0;
  let failed = 0;
  const failures: Array<Record<string, unknown>> = [];

  for (let i = 0; i < tokens.length; i += concurrency) {
    const batch = tokens.slice(i, i + concurrency);
    const results = await Promise.all(batch.map(sendOne));
    for (const r of results) {
      if (r.ok) sent++;
      else {
        failed++;
        failures.push(r);
      }
    }
  }

  return jsonResponse({ ok: true, sent, failed, failures: failures.slice(0, 5) });
});
