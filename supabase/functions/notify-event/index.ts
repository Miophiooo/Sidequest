// Supabase Edge Function: notify-event
// Called by Postgres (public.notify_event via pg_net) for every event push:
// chat messages, reactions, friend requests (+ reminder), duels, comments,
// likes, friends' posts and the daily Crowd Favorite title. Checks blocks
// and the recipient's notification settings and writes the text in the
// recipient's language (users_profile.language, German by default).
//
// Auth: header x-internal-secret must match the Vault secret
// `daily_scheduler_cron_secret` (shared with daily-scheduler and the database
// triggers).
//
// Internally calls the existing `send-push` function with the Vault secret
// `push_secret` so all FCM/token-cleanup logic stays in one place.

declare const Deno: any;

// @ts-ignore
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Kind =
  | "chat_message"
  | "message_reaction"
  | "pvp_challenge"
  | "duel_invite"
  | "duel_accepted"
  | "duel_result"
  | "friend_request"
  | "friend_request_reminder"
  | "friend_accepted"
  | "comment"
  | "like"
  | "friend_post"
  | "crowd_favorite";

const KINDS: ReadonlySet<string> = new Set<Kind>([
  "chat_message",
  "message_reaction",
  "pvp_challenge",
  "duel_invite",
  "duel_accepted",
  "duel_result",
  "friend_request",
  "friend_request_reminder",
  "friend_accepted",
  "comment",
  "like",
  "friend_post",
  "crowd_favorite",
]);

type Body = {
  kind: Kind;
  sender_id: string;
  // Not used for friend_post: that one goes to the sender's friends.
  // crowd_favorite: the winner is sender and recipient.
  recipient_id?: string;
  extra?: Record<string, unknown>;
};

type Lang = "de" | "en";

// Main tab indices in the app; tapping the push opens that tab.
const HOME_TAB = "0";
const FRIENDS_TAB = "1";
const GLOBAL_TAB = "2";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function getSupabaseUrl(): string {
  return Deno.env.get("SUPABASE_URL") ?? Deno.env.get("SB_URL") ?? requireEnv("SB_URL");
}

function getServiceRoleKey(): string {
  return (
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SERVICE_ROLE_KEY") ??
    Deno.env.get("SB_SERVICE_ROLE_KEY") ??
    requireEnv("SERVICE_ROLE_KEY")
  );
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

function truncate(s: string, max = 80): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1) + "…";
}

// Column in `user_notification_prefs` that lets the recipient turn this push
// off. `null` = no setting, always sent.
const prefColumnByKind: Record<Kind, string | null> = {
  chat_message: "messages",
  message_reaction: "messages",
  pvp_challenge: "challenged",
  duel_invite: "challenged",
  duel_accepted: "challenged",
  duel_result: "challenged",
  friend_request: null,
  friend_request_reminder: null,
  friend_accepted: null,
  comment: null,
  like: null,
  friend_post: "friends_posts",
  crowd_favorite: null,
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Db = any;

/** Recipients that still want this kind (missing row or value = yes). */
async function filterByPrefs(
  supabase: Db,
  recipientIds: string[],
  kind: Kind,
): Promise<string[]> {
  const col = prefColumnByKind[kind];
  if (!col || recipientIds.length === 0) return recipientIds;

  const { data, error } = await supabase
    .from("user_notification_prefs")
    .select(`user_id, ${col}`)
    .in("user_id", recipientIds);
  if (error) {
    // If lookup fails, default to sending — better noisy than silent.
    console.error("prefs lookup failed", error);
    return recipientIds;
  }
  const optedOut = new Set<string>();
  for (const row of (data ?? []) as Array<Record<string, unknown>>) {
    if (row[col] === false) optedOut.add(String(row.user_id));
  }
  return recipientIds.filter((id) => !optedOut.has(id));
}

/** Drops recipients who blocked the sender or were blocked by them. */
async function filterBlocked(
  supabase: Db,
  senderId: string,
  recipientIds: string[],
): Promise<string[]> {
  if (recipientIds.length === 0) return recipientIds;
  const { data, error } = await supabase
    .from("user_blocks")
    .select("blocker_id, blocked_id")
    .or(`blocker_id.eq.${senderId},blocked_id.eq.${senderId}`);
  if (error) {
    console.error("block lookup failed", error);
    return recipientIds;
  }
  const blocked = new Set<string>();
  for (const row of (data ?? []) as Array<Record<string, string>>) {
    blocked.add(row.blocker_id === senderId ? row.blocked_id : row.blocker_id);
  }
  return recipientIds.filter((id) => !blocked.has(id));
}

async function acceptedFriendIds(supabase: Db, userId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from("friends")
    .select("user_id, friend_id")
    .eq("status", "accepted")
    .or(`user_id.eq.${userId},friend_id.eq.${userId}`);
  if (error) {
    console.error("friends lookup failed", error);
    return [];
  }
  const ids = new Set<string>();
  for (const row of (data ?? []) as Array<Record<string, string>>) {
    const other = row.user_id === userId ? row.friend_id : row.user_id;
    if (other && other !== userId) ids.add(other);
  }
  return [...ids];
}

/** Recipients grouped by their app language (German if unknown). */
async function groupByLanguage(
  supabase: Db,
  recipientIds: string[],
): Promise<Map<Lang, string[]>> {
  const groups = new Map<Lang, string[]>();
  const { data, error } = await supabase
    .from("users_profile")
    .select("id, language")
    .in("id", recipientIds);
  if (error) console.error("language lookup failed", error);
  const langById = new Map<string, Lang>();
  for (const row of (data ?? []) as Array<Record<string, string>>) {
    langById.set(row.id, row.language === "en" ? "en" : "de");
  }
  for (const id of recipientIds) {
    const lang = langById.get(id) ?? "de";
    groups.set(lang, [...(groups.get(lang) ?? []), id]);
  }
  return groups;
}

async function senderUsername(supabase: Db, senderId: string): Promise<string | null> {
  const { data, error } = await supabase
    .from("users_profile")
    .select("username")
    .eq("id", senderId)
    .maybeSingle();
  if (error || !data) return null;
  const username = (data as { username?: string }).username;
  return username && username.trim().length > 0 ? username.trim() : null;
}

function str(value: unknown): string {
  return value === undefined || value === null ? "" : String(value);
}

/** Exported for tests: the push text for one language. */
export function renderNotification(
  kind: Kind,
  lang: Lang,
  senderName: string | null,
  extra: Record<string, unknown> = {},
): { title: string; body: string; data: Record<string, string> } {
  const de = lang === "de";
  const who = senderName ?? (de ? "Jemand" : "Someone");
  const at = senderName ? `@${senderName}` : who;
  const photoTab = extra.is_public === true || extra.is_public === "true"
    ? GLOBAL_TAB
    : HOME_TAB;
  const base = { kind, sender_id: str(extra.sender_id) };

  switch (kind) {
    case "chat_message": {
      const msg = str(extra.message).trim();
      return {
        title: who,
        body: msg.length > 0
          ? truncate(msg, 120)
          : de ? "Hat dir eine Nachricht geschickt" : "Sent you a message",
        // "message" is what the app opens the chat for.
        data: {
          ...base,
          kind: "message",
          target_tab: FRIENDS_TAB,
          message_id: str(extra.message_id),
        },
      };
    }
    case "message_reaction": {
      const emoji = str(extra.emoji).trim() || "❤️";
      return {
        title: who,
        body: de
          ? `${emoji} hat auf deine Nachricht reagiert`
          : `${emoji} reacted to your message`,
        data: { ...base, target_tab: FRIENDS_TAB, message_id: str(extra.message_id), emoji },
      };
    }
    case "pvp_challenge":
    case "duel_invite":
      return {
        title: de ? "Neues Duell! ⚔️" : "New duel! ⚔️",
        body: de
          ? `${who} fordert dich zum Duell heraus – du hast 2 Stunden zum Annehmen.`
          : `${who} challenged you to a duel – you have 2 hours to accept.`,
        data: { ...base, target_tab: FRIENDS_TAB, challenge_id: str(extra.challenge_id) },
      };
    case "duel_accepted":
      return {
        title: de ? "Duell angenommen! ⚔️" : "Duel accepted! ⚔️",
        body: de
          ? `${who} hat angenommen – du hast 30 Minuten für dein Foto.`
          : `${who} accepted – you have 30 minutes for your photo.`,
        data: { ...base, target_tab: FRIENDS_TAB, challenge_id: str(extra.challenge_id) },
      };
    case "duel_result": {
      // extra.recipient_id: who gets this push; extra.winner_id: "" on a tie.
      const winner = str(extra.winner_id);
      const won = winner !== "" && winner === str(extra.recipient_id);
      const lost = winner !== "" && !won;
      const hadPhotos = extra.had_photos === true || extra.had_photos === "true";
      const [title, body] = won
        ? de
          ? ["Duell gewonnen! 🏆", `Du hast das Duell gegen ${who} gewonnen.`]
          : ["Duel won! 🏆", `You won the duel against ${who}.`]
        : lost
          ? de
            ? ["Duell verloren ⚔️", `${who} hat das Duell gewonnen – Zeit für eine Revanche?`]
            : ["Duel lost ⚔️", `${who} won the duel – time for a rematch?`]
          : hadPhotos
            ? de
              ? ["Unentschieden 🤝", `Dein Duell gegen ${who} endet unentschieden.`]
              : ["It's a draw 🤝", `Your duel against ${who} ended in a draw.`]
            : de
              ? ["Duell abgelaufen", `Im Duell gegen ${who} hat niemand ein Foto gepostet.`]
              : ["Duel expired", `Nobody posted a photo in the duel against ${who}.`];
      return {
        title,
        body,
        data: { ...base, target_tab: FRIENDS_TAB, challenge_id: str(extra.challenge_id) },
      };
    }
    case "friend_request":
      return {
        title: de ? "Neue Freundschaftsanfrage" : "New friend request",
        body: de
          ? `${who} möchte mit dir befreundet sein – tipp zum Annehmen.`
          : `${who} wants to add you as a friend – tap to accept.`,
        data: { ...base, target_tab: FRIENDS_TAB, friendship_id: str(extra.friendship_id) },
      };
    case "friend_request_reminder":
      return {
        title: de ? "Anfrage wartet noch 👋" : "Friend request waiting 👋",
        body: de
          ? `${who} wartet auf deine Antwort – tipp zum Annehmen.`
          : `${who} is still waiting for your answer – tap to accept.`,
        data: { ...base, target_tab: FRIENDS_TAB, friendship_id: str(extra.friendship_id) },
      };
    case "friend_accepted":
      return {
        title: de ? "Anfrage angenommen 🎉" : "Friend request accepted 🎉",
        body: de
          ? `${who} ist jetzt mit dir befreundet.`
          : `${who} accepted your friend request.`,
        data: { ...base, target_tab: FRIENDS_TAB, friendship_id: str(extra.friendship_id) },
      };
    case "comment": {
      const msg = str(extra.message).trim();
      return {
        title: "SideQuest",
        body: msg.length > 0
          ? `💬 ${at}: ${truncate(msg, 120)}`
          : de ? `💬 ${at} hat dein Foto kommentiert` : `💬 ${at} commented on your photo`,
        data: {
          ...base,
          target_tab: photoTab,
          photo_id: str(extra.photo_id),
          comment_id: str(extra.comment_id),
        },
      };
    }
    case "like":
      return {
        title: "SideQuest",
        body: de ? `❤️ ${at} gefällt dein Foto` : `❤️ ${at} liked your photo`,
        data: { ...base, target_tab: photoTab, photo_id: str(extra.photo_id) },
      };
    case "friend_post":
      return {
        title: "SideQuest",
        body: de ? `📸 ${who} hat gerade gepostet` : `📸 ${who} just posted`,
        data: {
          ...base,
          kind: "friends_post",
          target_tab: photoTab,
          poster_id: str(extra.sender_id),
          photo_id: str(extra.photo_id),
          is_public: photoTab === GLOBAL_TAB ? "true" : "false",
        },
      };
    case "crowd_favorite": {
      const bonus = Number(extra.joker_bonus ?? 3) || 3;
      return {
        title: de ? "👑 Du bist Crowd Favorite!" : "👑 You're Crowd Favorite!",
        body: de
          ? `Dein Foto hatte heute die meisten Likes – +${bonus} Joker 🃏`
          : `Your photo got the most likes today – +${bonus} jokers 🃏`,
        data: { ...base, target_tab: GLOBAL_TAB, photo_id: str(extra.photo_id) },
      };
    }
  }
}

async function callSendPush(
  supabaseUrl: string,
  pushSecret: string,
  payload: {
    type: string;
    recipient_user_ids: string[];
    title: string;
    body: string;
    data?: Record<string, string>;
  },
) {
  const res = await fetch(`${supabaseUrl}/functions/v1/send-push`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-push-secret": pushSecret,
    },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`send-push failed (${res.status}): ${text}`);
  }
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text };
  }
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "method_not_allowed" }, 405);
    }

    const supabase = createClient(getSupabaseUrl(), getServiceRoleKey(), {
      auth: { persistSession: false },
    });

    const got = req.headers.get("x-internal-secret") ?? "";
    if (!(await secretMatches(supabase, "daily_scheduler_cron_secret", got))) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    const body = (await req.json()) as Body;
    if (!body || !KINDS.has(body.kind) || !body.sender_id) {
      return jsonResponse({ error: "missing_fields" }, 400);
    }

    let recipients: string[];
    if (body.kind === "friend_post") {
      recipients = await acceptedFriendIds(supabase, body.sender_id);
    } else if (!body.recipient_id) {
      return jsonResponse({ error: "missing_fields" }, 400);
    } else {
      recipients = [body.recipient_id];
    }

    // Never push to yourself (except the system push crowd_favorite).
    recipients = recipients.filter(
      (id) => id && (body.kind === "crowd_favorite" || id !== body.sender_id),
    );
    recipients = await filterBlocked(supabase, body.sender_id, recipients);
    recipients = await filterByPrefs(supabase, recipients, body.kind);
    if (recipients.length === 0) {
      return jsonResponse({ ok: true, skipped: "no_recipients" });
    }

    const sender = await senderUsername(supabase, body.sender_id);
    const pushSecret = await loadSecret(supabase, "push_secret");
    const sent: Record<string, unknown> = {};
    for (const [lang, ids] of await groupByLanguage(supabase, recipients)) {
      const note = renderNotification(body.kind, lang, sender, {
        ...(body.extra ?? {}),
        sender_id: body.sender_id,
      });
      sent[lang] = await callSendPush(getSupabaseUrl(), pushSecret, {
        type: body.kind,
        recipient_user_ids: ids,
        title: note.title,
        body: note.body,
        data: note.data,
      });
    }

    return jsonResponse({ ok: true, sent });
  } catch (e: unknown) {
    const msg =
      e instanceof Error
        ? e.message
        : typeof e === "string"
          ? e
          : JSON.stringify(e);
    return jsonResponse({ ok: false, error: msg }, 500);
  }
});
