// Supabase Edge Function: delete-account
// Self-service account deletion (App Store 5.1.1(v), Play data deletion,
// GDPR Art. 17). Called by the signed-in app with the user's JWT.
//
// 1. Removes the user's files from storage: photos/<uid>/** (posts, live
//    photo stills and clips) and profile_pictures/profile_<uid>*. The
//    database can't do this itself (direct storage.objects deletes are
//    blocked by Supabase), and the old flow left all files behind.
// 2. Calls public.delete_own_account() as the user, which removes the rows
//    and the auth user in one transaction.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const Deno: any;

// @ts-ignore
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...corsHeaders },
  });
}

function env(...names: string[]): string {
  for (const name of names) {
    const value = Deno.env.get(name);
    if (value) return value;
  }
  throw new Error(`Missing env ${names[0]}`);
}

// Lists every object below `prefix` (folders are listed recursively).
async function listAllObjects(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  admin: any,
  bucket: string,
  prefix: string,
  depth = 0,
): Promise<string[]> {
  const paths: string[] = [];
  const pageSize = 1000;
  for (let offset = 0; ; offset += pageSize) {
    const { data, error } = await admin.storage
      .from(bucket)
      .list(prefix, { limit: pageSize, offset });
    if (error) throw new Error(`list ${bucket}/${prefix} failed: ${error.message}`);
    const entries = (data ?? []) as Array<{ name: string; id: string | null }>;
    for (const entry of entries) {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.id === null) {
        if (depth < 4) paths.push(...(await listAllObjects(admin, bucket, path, depth + 1)));
      } else {
        paths.push(path);
      }
    }
    if (entries.length < pageSize) break;
  }
  return paths;
}

async function removeObjects(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  admin: any,
  bucket: string,
  paths: string[],
): Promise<number> {
  let removed = 0;
  for (let i = 0; i < paths.length; i += 100) {
    const batch = paths.slice(i, i + 100);
    const { error } = await admin.storage.from(bucket).remove(batch);
    if (error) throw new Error(`remove from ${bucket} failed: ${error.message}`);
    removed += batch.length;
  }
  return removed;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  try {
    const supabaseUrl = env("SUPABASE_URL", "SB_URL");
    const admin = createClient(
      supabaseUrl,
      env("SUPABASE_SERVICE_ROLE_KEY", "SERVICE_ROLE_KEY", "SB_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );

    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    const uid: string | undefined = userData?.user?.id;
    if (userError || !uid) return jsonResponse({ error: "unauthorized" }, 401);

    const photoPaths = await listAllObjects(admin, "photos", uid);
    const removedPhotos = await removeObjects(admin, "photos", photoPaths);

    const { data: avatarRows, error: avatarError } = await admin.storage
      .from("profile_pictures")
      .list("", { limit: 100, search: `profile_${uid}` });
    if (avatarError) throw new Error(`list profile_pictures failed: ${avatarError.message}`);
    const avatarPaths = ((avatarRows ?? []) as Array<{ name: string }>)
      .map((row) => row.name)
      .filter((name) => name.startsWith(`profile_${uid}`));
    const removedAvatars = await removeObjects(admin, "profile_pictures", avatarPaths);

    // Run the SQL deletion as the user so auth.uid() is set.
    const userClient = createClient(
      supabaseUrl,
      env("SUPABASE_ANON_KEY", "SB_ANON_KEY"),
      {
        auth: { persistSession: false },
        global: { headers: { Authorization: `Bearer ${jwt}` } },
      },
    );
    const { error: rpcError } = await userClient.rpc("delete_own_account");
    if (rpcError) {
      return jsonResponse({ ok: false, error: "delete_failed", detail: rpcError.message }, 500);
    }

    return jsonResponse({
      ok: true,
      removed_files: removedPhotos + removedAvatars,
    });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("delete-account failed", msg);
    return jsonResponse({ ok: false, error: "delete_failed" }, 500);
  }
});
