// Supabase Edge Function: invite
// Public friend-invite link: /functions/v1/invite?u=<username>
//
// Redirects into the app via its URL scheme (io.supabase.sidequest://invite).
// The app then sends a friend request to <username>. Android gets an
// intent:// URL so Chrome falls back to the Play Store when the app isn't
// installed. Supabase doesn't serve HTML on *.supabase.co, so a proper
// landing page (and universal links) needs our own domain later.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const Deno: any;

// Same characters as lib/username_filter.dart; longer limit so older
// usernames still work.
const USERNAME = /^[A-Za-z0-9_ÄÖÜßäöüẞ]{1,32}$/u;
const PLAY_STORE_URL = "https://play.google.com/store/apps/details?id=app.sidequest";

Deno.serve((req: Request) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405 });
  }

  const username = (new URL(req.url).searchParams.get("u") ?? "").trim();
  if (!USERNAME.test(username)) {
    return new Response("Invalid invite link", { status: 400 });
  }

  const query = `u=${encodeURIComponent(username)}`;
  const userAgent = req.headers.get("user-agent") ?? "";
  const location = /android/i.test(userAgent)
    ? `intent://invite?${query}#Intent;scheme=io.supabase.sidequest;package=app.sidequest;` +
      `S.browser_fallback_url=${encodeURIComponent(PLAY_STORE_URL)};end`
    : `io.supabase.sidequest://invite?${query}`;

  return new Response(null, {
    status: 302,
    headers: { location, "cache-control": "no-store" },
  });
});
