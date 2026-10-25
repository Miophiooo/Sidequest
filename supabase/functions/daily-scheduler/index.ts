// Supabase Edge Function: daily-scheduler
// - Triggers daily push notifications:
//   - when the daily challenge starts (London-time based)
//   - 1 hour before the daily challenge ends: streak warning for users with a
//     streak who haven't posted yet
//   - 10 minutes before the daily challenge ends, to users who haven't posted
// - Texts in each user's language (users_profile.language, German default).
// - Calls the existing `send-push` function so we keep all FCM + token cleanup logic in one place.
// - Uses an idempotency table `push_cron_runs` to avoid duplicate sends.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const Deno: any;

// @ts-ignore
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Kind = "challenge_start" | "challenge_ending";

type RunKind = Kind | "streak_warning";

type BadgeKind = "crowd_favorite_award";

type Lang = "de" | "en";

type ScheduledPush = Kind | "streak_warning";

type ForceRequest = {
  force_kind?: Kind | "both";
  recipient_user_ids?: string[];
  dry_run?: boolean;
};

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

/** Exported for tests: title and body of a scheduled push. */
export function renderScheduledPush(
  kind: ScheduledPush,
  lang: Lang,
): { title: string; body: string } {
  const de = lang === "de";
  switch (kind) {
    case "challenge_start":
      return de
        ? { title: "Neue Daily Quest! 📸", body: "Die heutige Quest ist da – öffne die App und leg los." }
        : { title: "New Daily Quest! 📸", body: "Today's quest is live – open the app and get going." };
    case "challenge_ending":
      return de
        ? { title: "Noch 10 Minuten! ⏰", body: "Schnell – die heutige Quest endet gleich." }
        : { title: "10 minutes left! ⏰", body: "Hurry up – today's quest ends soon." };
    case "streak_warning":
      return de
        ? { title: "🔥 Streak in Gefahr!", body: "Noch 1 Stunde – poste dein Foto, damit deine Streak nicht reißt." }
        : { title: "🔥 Streak in danger!", body: "1 hour left – post your photo so your streak doesn't break." };
  }
}

/** Recipients grouped by their app language (German if unknown). */
async function groupByLanguage(
  supabase: ReturnType<typeof createClient>,
  recipientIds: string[],
): Promise<Map<Lang, string[]>> {
  const langById = new Map<string, Lang>();
  for (let i = 0; i < recipientIds.length; i += 200) {
    const { data, error } = await supabase
      .from("users_profile")
      .select("id, language")
      .in("id", recipientIds.slice(i, i + 200));
    if (error) console.error("language lookup failed", error);
    for (const row of (data ?? []) as Array<Record<string, string>>) {
      langById.set(row.id, row.language === "en" ? "en" : "de");
    }
  }
  const groups = new Map<Lang, string[]>();
  for (const id of recipientIds) {
    const lang = langById.get(id) ?? "de";
    groups.set(lang, [...(groups.get(lang) ?? []), id]);
  }
  return groups;
}

function pad2(n: number) {
  return String(n).padStart(2, "0");
}

function londonDateStrFromLondonDay(londonDay: Date) {
  // londonDay is already in London-local components.
  const y = londonDay.getFullYear();
  const m = pad2(londonDay.getMonth() + 1);
  const d = pad2(londonDay.getDate());
  return `${y}-${m}-${d}`;
}

function lastSundayOfMonthUtc(year: number, month1Based: number, hourUtc: number): Date {
  // month1Based: 1..12
  const firstNextMonthUtc = new Date(Date.UTC(year, month1Based, 1, hourUtc, 0, 0, 0));
  const lastDayUtc = new Date(firstNextMonthUtc.getTime() - 24 * 60 * 60 * 1000);
  // JS getUTCDay(): 0=Sun..6=Sat
  const delta = lastDayUtc.getUTCDay();
  return new Date(
    Date.UTC(
      year,
      month1Based - 1,
      lastDayUtc.getUTCDate() - (delta === 0 ? 0 : delta),
      hourUtc,
      0,
      0,
      0,
    ),
  );
}

function londonOffsetHoursForUtc(utc: Date): number {
  const y = utc.getUTCFullYear();
  const start = lastSundayOfMonthUtc(y, 3, 1); // last Sunday March 01:00 UTC
  const end = lastSundayOfMonthUtc(y, 10, 1); // last Sunday Oct 01:00 UTC
  const t = utc.getTime();
  const inDst = t >= start.getTime() && t < end.getTime();
  return inDst ? 1 : 0;
}

function toLondonTime(utc: Date): Date {
  const offsetHours = londonOffsetHoursForUtc(utc);
  return new Date(utc.getTime() + offsetHours * 60 * 60 * 1000);
}

function londonDateOnlyFromUtc(utc: Date): Date {
  const l = toLondonTime(utc);
  return new Date(l.getFullYear(), l.getMonth(), l.getDate());
}

function sameLocalComponents(a: Date, b: Date) {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate() &&
    a.getHours() === b.getHours() &&
    a.getMinutes() === b.getMinutes() &&
    a.getSeconds() === b.getSeconds() &&
    a.getMilliseconds() === b.getMilliseconds()
  );
}

function londonLocalToUtc(londonLocal: Date): Date {
  // Interpret the provided Date components as London local time.
  const naiveUtc = new Date(
    Date.UTC(
      londonLocal.getFullYear(),
      londonLocal.getMonth(),
      londonLocal.getDate(),
      londonLocal.getHours(),
      londonLocal.getMinutes(),
      londonLocal.getSeconds(),
      londonLocal.getMilliseconds(),
    ),
  );

  const candidate0 = naiveUtc; // offset 0
  if (sameLocalComponents(toLondonTime(candidate0), londonLocal)) return candidate0;

  const candidate1 = new Date(naiveUtc.getTime() - 60 * 60 * 1000); // offset +1
  if (sameLocalComponents(toLondonTime(candidate1), londonLocal)) return candidate1;

  const offsetHours = londonOffsetHoursForUtc(naiveUtc);
  return new Date(naiveUtc.getTime() - offsetHours * 60 * 60 * 1000);
}

function daysSinceAnchor(londonDay: Date): number {
  // Counted in UTC so the runtime time zone can't shift it by a day.
  const dayUtc = Date.UTC(londonDay.getFullYear(), londonDay.getMonth(), londonDay.getDate());
  const anchorUtc = Date.UTC(2024, 0, 1);
  return Math.round((dayUtc - anchorUtc) / (24 * 60 * 60 * 1000));
}

// From this day index on (2026-10-27) the challenge starts at a pseudo-random
// time between 09:00 and 18:59 London. Keep identical to `lib/london_time.dart`
// and `public.challenge_day_bounds()`.
const kRandomChallengeStartDayIndex = 1030;

function challengeStartMinuteOfDayForLondonDay(londonDay: Date): number {
  const d = daysSinceAnchor(londonDay);
  if (d < kRandomChallengeStartDayIndex) {
    return 8 * 60 + ((d * 7919) % 120);
  }
  return 9 * 60 + ((d * d * 31 + d * 7919 + 101) % 600);
}

function challengeStartLondonForDay(londonDay: Date): Date {
  const minuteOfDay = challengeStartMinuteOfDayForLondonDay(londonDay);
  return new Date(
    londonDay.getFullYear(),
    londonDay.getMonth(),
    londonDay.getDate(),
    Math.floor(minuteOfDay / 60),
    minuteOfDay % 60,
    0,
    0,
  );
}

function challengeStartUtcForLondonDay(londonDay: Date): Date {
  return londonLocalToUtc(challengeStartLondonForDay(londonDay));
}

const kDailyChallengeDifficulties: Array<"easy" | "medium" | "hard"> = [
  "medium",
  "easy",
  "medium",
];

function dailyDifficultyForLondonDay(londonDay: Date): "easy" | "medium" | "hard" {
  const idx = ((daysSinceAnchor(londonDay) % kDailyChallengeDifficulties.length) +
    kDailyChallengeDifficulties.length) %
    kDailyChallengeDifficulties.length;
  return kDailyChallengeDifficulties[idx];
}

function dailyEndLondonForDay(londonDay: Date): Date {
  const start = challengeStartLondonForDay(londonDay);
  const difficulty = dailyDifficultyForLondonDay(londonDay);
  const hours = difficulty === "easy" ? 2 : difficulty === "hard" ? 9 : 5;

  return new Date(start.getTime() + hours * 60 * 60 * 1000);
}

function dailyEndUtcForLondonDay(londonDay: Date): Date {
  return londonLocalToUtc(dailyEndLondonForDay(londonDay));
}

function shouldFire(nowUtc: Date, targetUtc: Date, windowMs = 2 * 60 * 1000): boolean {
  const delta = nowUtc.getTime() - targetUtc.getTime();
  return delta >= 0 && delta < windowMs;
}

async function alreadyRan(
  supabase: ReturnType<typeof createClient>,
  kind: RunKind,
  londonDateStr: string,
): Promise<boolean> {
  // Use the idempotency table. Insert-once; if it already exists, skip.
  const { error } = await supabase
    .from("push_cron_runs")
    .insert({ kind, london_date: londonDateStr })
    .select("kind")
    .maybeSingle();

  if (!error) return false;

  // PostgREST returns 409 / duplicate key as error; supabase-js wraps it.
  // We treat any conflict-like error as "already ran".
  const msg = String((error as any)?.message ?? error);
  if (msg.toLowerCase().includes("duplicate") || msg.includes("23505") || msg.includes("409")) {
    return true;
  }

  // If table missing, surface it clearly.
  if (msg.toLowerCase().includes("push_cron_runs") && msg.toLowerCase().includes("does not exist")) {
    throw new Error(
      "Missing table push_cron_runs. Run PUSH_CRON_RUNS_TABLE.sql in Supabase SQL editor.",
    );
  }

  throw error;
}

async function getRecipients(
  supabase: ReturnType<typeof createClient>,
  kind: Kind,
): Promise<string[]> {
  const { data: tokenRows, error: tokenError } = await supabase
    .from("user_device_tokens")
    .select("user_id");

  if (tokenError) throw tokenError;

  const tokenUserIds = new Set(
    (tokenRows ?? []).map((row: any) => String(row.user_id ?? "")).filter(Boolean),
  );
  if (tokenUserIds.size === 0) return [];

  const userIds = [...tokenUserIds];
  const { data: prefsRows, error: prefsError } = await supabase
    .from("user_notification_prefs")
    .select(`user_id, ${kind}`)
    .in("user_id", userIds);

  if (prefsError) throw prefsError;

  // Match send-push behavior:
  // - explicit false disables the scheduled push
  // - missing prefs row defaults to true
  const allowedUserIds = new Set(userIds);
  for (const row of (prefsRows ?? []) as Array<Record<string, unknown>>) {
    const id = typeof row.user_id === "string" ? row.user_id : "";
    if (!id) continue;
    if (row[kind] === false) {
      allowedUserIds.delete(id);
    }
  }

  return [...allowedUserIds];
}

// Of `userIds`, those who haven't posted for today's quest yet (the streak
// trigger sets last_posted_date on every quest post). With `streakOnly`
// only users with a running streak.
async function notPostedToday(
  supabase: ReturnType<typeof createClient>,
  userIds: string[],
  londonDateStr: string,
  streakOnly = false,
): Promise<string[]> {
  const result: string[] = [];
  for (let i = 0; i < userIds.length; i += 200) {
    let query = supabase
      .from("users_profile")
      .select("id, flames, last_posted_date")
      .in("id", userIds.slice(i, i + 200));
    if (streakOnly) query = query.gte("flames", 1);
    const { data, error } = await query;
    if (error) throw error;
    for (const row of (data ?? []) as Array<Record<string, unknown>>) {
      if (row.last_posted_date === londonDateStr) continue;
      const id = String(row.id ?? "");
      if (id) result.push(id);
    }
  }
  return result;
}

// Users with a running streak who haven't posted for today's challenge yet.
async function getStreakWarningRecipients(
  supabase: ReturnType<typeof createClient>,
  londonDateStr: string,
): Promise<string[]> {
  const allowed = await getRecipients(supabase, "challenge_ending");
  if (allowed.length === 0) return [];
  return notPostedToday(supabase, allowed, londonDateStr, true);
}

async function callSendPush(
  supabaseUrl: string,
  pushSecret: string,
  payload: {
    type: Kind;
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
    const supabaseUrl = getSupabaseUrl();
    const serviceRoleKey = getServiceRoleKey();
    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    });

    const got = req.headers.get("x-cron-secret") ?? "";
    if (!(await secretMatches(supabase, "daily_scheduler_cron_secret", got))) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    const pushSecret = await loadSecret(supabase, "push_secret");

    const nowUtc = new Date();
    const londonDay = londonDateOnlyFromUtc(nowUtc);
    const londonDateStr = londonDateStrFromLondonDay(londonDay);

    const startUtc = challengeStartUtcForLondonDay(londonDay);
    const endUtc = dailyEndUtcForLondonDay(londonDay);
    // 10 minutes before end (was 30 — user wants tighter warning window).
    const endingSoonUtc = new Date(endUtc.getTime() - 10 * 60 * 1000);
    const streakWarningUtc = new Date(endUtc.getTime() - 60 * 60 * 1000);

    // Optional manual test mode.
    // This is useful because the normal path only fires inside a small time window.
    let force: ForceRequest | null = null;
    if (req.method !== "GET") {
      try {
        const body = await req.json();
        if (body && typeof body === "object") {
          force = body as ForceRequest;
        }
      } catch {
        // ignore non-JSON bodies
      }
    }

    const actions: Array<{ kind: Kind; sent: boolean; info?: unknown }> = [];
    const badgeActions: Array<{ kind: BadgeKind; awarded: boolean; info?: unknown }> = [];

    // One send-push call per language. The streak warning goes out with the
    // challenge_ending setting, like before.
    const doSend = async (push: ScheduledPush, recipients: string[]) => {
      const kind: Kind = push === "challenge_start" ? "challenge_start" : "challenge_ending";
      if (recipients.length === 0) {
        return { kind, sent: false, info: `${push}_no_recipients` };
      }
      const payloads: Array<{
        type: Kind;
        recipient_user_ids: string[];
        title: string;
        body: string;
        data: Record<string, string>;
      }> = [];
      for (const [lang, ids] of await groupByLanguage(supabase, recipients)) {
        payloads.push({
          type: kind,
          recipient_user_ids: ids,
          ...renderScheduledPush(push, lang),
          data: { london_date: londonDateStr, kind: push },
        });
      }

      if (force?.dry_run) {
        return { kind, sent: false, info: { dry_run: true, payloads } };
      }

      const info: unknown[] = [];
      for (const payload of payloads) {
        info.push(await callSendPush(supabaseUrl, pushSecret, payload));
      }
      return { kind, sent: true, info };
    };

    if (force?.force_kind) {
      const recipients = (force.recipient_user_ids ?? []).map(String).filter(Boolean);
      if (recipients.length === 0) {
        return jsonResponse(
          {
            ok: false,
            error:
              "force_kind provided but recipient_user_ids is empty. Provide your own user id to avoid spamming everyone.",
          },
          400,
        );
      }

      if (force.force_kind === "both") {
        actions.push(await doSend("challenge_start", recipients));
        actions.push(await doSend("challenge_ending", recipients));
      } else {
        actions.push(await doSend(force.force_kind, recipients));
      }

      return jsonResponse({
        ok: true,
        mode: "force",
        now_utc: nowUtc.toISOString(),
        london_date: londonDateStr,
        start_utc: startUtc.toISOString(),
        end_utc: endUtc.toISOString(),
        ending_soon_utc: endingSoonUtc.toISOString(),
        streak_warning_utc: streakWarningUtc.toISOString(),
        actions,
        badge_actions: badgeActions,
      });
    }

    // Challenge start
    if (shouldFire(nowUtc, startUtc)) {
      const ran = await alreadyRan(supabase, "challenge_start", londonDateStr);
      if (!ran) {
        const recipients = await getRecipients(supabase, "challenge_start");
        actions.push(await doSend("challenge_start", recipients));
      } else {
        actions.push({ kind: "challenge_start", sent: false, info: "already_ran" });
      }
    }

    // 1 hour before end: warn users whose streak is about to break.
    if (shouldFire(nowUtc, streakWarningUtc)) {
      const ran = await alreadyRan(supabase, "streak_warning", londonDateStr);
      if (ran) {
        actions.push({ kind: "challenge_ending", sent: false, info: "streak_warning_already_ran" });
      } else {
        const recipients = await getStreakWarningRecipients(supabase, londonDateStr);
        actions.push(await doSend("streak_warning", recipients));
      }
    }

    // 10 minutes before end
    if (shouldFire(nowUtc, endingSoonUtc)) {
      const ran = await alreadyRan(supabase, "challenge_ending", londonDateStr);
      if (!ran) {
        // Only people who still have to post.
        const recipients = await notPostedToday(
          supabase,
          await getRecipients(supabase, "challenge_ending"),
          londonDateStr,
        );
        actions.push(await doSend("challenge_ending", recipients));
      } else {
        actions.push({ kind: "challenge_ending", sent: false, info: "already_ran" });
      }
    }

    // Award Crowd Favorite shortly after end (allows last-second votes to land).
    const awardUtc = new Date(endUtc.getTime() + 60 * 1000);
    if (shouldFire(nowUtc, awardUtc, 5 * 60 * 1000)) {
      const { data, error } = await supabase.rpc("award_crowd_favorite_window", {
        london_date_str: londonDateStr,
        start_utc: startUtc.toISOString(),
        end_utc: endUtc.toISOString(),
      });

      if (error) {
        badgeActions.push({ kind: "crowd_favorite_award", awarded: false, info: String(error) });
      } else {
        badgeActions.push({
          kind: "crowd_favorite_award",
          awarded: Boolean((data as any)?.awarded),
          info: data,
        });
      }
    }

    return jsonResponse({
      ok: true,
      now_utc: nowUtc.toISOString(),
      london_date: londonDateStr,
      start_utc: startUtc.toISOString(),
      end_utc: endUtc.toISOString(),
      ending_soon_utc: endingSoonUtc.toISOString(),
      streak_warning_utc: streakWarningUtc.toISOString(),
      actions,
      badge_actions: badgeActions,
    });
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
