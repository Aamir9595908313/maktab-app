import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

// Sends a push notification (Firebase Cloud Messaging) to a student's parent
// when the student is marked absent. Called by the app right after the
// one-time absence-notification claim succeeds (student_attendance.
// absence_notified_at), so a given absence is only ever pushed once.
//
// Safety: the caller must be a signed-in, active teacher / Maktab admin /
// super admin who can actually see that attendance row (RLS decides), and the
// row must really be an absence that was claimed. The parent is found by the
// student's parent_phone -> user_profiles.phone -> their registered devices.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ACCOUNT_RAW = Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });
}

let cached: { token: string; exp: number } | null = null;
async function fcmAccessToken(sa: { client_email: string; private_key: string; token_uri?: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > now) return cached.token;
  const key = await importPKCS8(sa.private_key, "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience(sa.token_uri ?? "https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);
  const res = await fetch(sa.token_uri ?? "https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error("token exchange failed: " + res.status);
  const j = await res.json();
  cached = { token: j.access_token as string, exp: now + Number(j.expires_in ?? 3600) };
  return cached.token;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);
  if (!SERVICE_ACCOUNT_RAW) return json({ ok: false, error: "Push is not configured yet." }, 503);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "Invalid request" }, 400); }
  const studentId = String(body?.student_id ?? "");
  const date = String(body?.date ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(studentId) || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return json({ ok: false, error: "Invalid student or date" }, 400);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader) return json({ ok: false, error: "Not signed in" }, 401);
  const caller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
  const { data: who } = await caller.auth.getUser();
  if (!who?.user) return json({ ok: false, error: "Not signed in" }, 401);
  const { data: prof } = await caller.from("user_profiles").select("base_role, is_active").eq("id", who.user.id).maybeSingle();
  if (!prof?.is_active || !["teacher", "madrasa_admin", "super_admin"].includes(String(prof.base_role))) {
    return json({ ok: false, error: "Not allowed" }, 403);
  }

  // RLS-scoped: the caller must be able to see this exact attendance row.
  const { data: row } = await caller
    .from("student_attendance")
    .select("status, absence_notified_at, students(name, parent_phone, madrasas(name))")
    .eq("student_id", studentId)
    .eq("attendance_date", date)
    .maybeSingle();
  if (!row || row.status !== "absent" || !row.absence_notified_at) {
    return json({ ok: false, error: "No claimed absence for that student and date" }, 409);
  }
  // deno-lint-ignore no-explicit-any
  const student: any = (row as any).students;
  const parentDigits = String(student?.parent_phone ?? "").replace(/\D/g, "").slice(-10);
  if (parentDigits.length !== 10) return json({ ok: true, sent: 0, reason: "no parent phone" });

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: parent } = await admin.from("user_profiles").select("id").eq("phone", "91" + parentDigits).maybeSingle();
  if (!parent) return json({ ok: true, sent: 0, reason: "parent has not logged in" });
  const { data: tokens } = await admin.from("device_tokens").select("token").eq("user_id", parent.id);
  if (!tokens || tokens.length === 0) return json({ ok: true, sent: 0, reason: "no registered device" });

  let sa;
  try { sa = JSON.parse(SERVICE_ACCOUNT_RAW); } catch { return json({ ok: false, error: "Push is misconfigured." }, 500); }
  let access: string;
  try { access = await fcmAccessToken(sa); } catch { return json({ ok: false, error: "Could not reach the push service." }, 502); }

  const maktab = student?.madrasas?.name ? ` (${student.madrasas.name})` : "";
  const title = "Absence alert";
  const text = `${student?.name ?? "Your child"} was absent today${maktab}.`;
  let sent = 0;
  for (const t of tokens as { token: string }[]) {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token: t.token,
          notification: { title, body: text },
          data: { type: "absence", student_id: studentId, date },
          android: { priority: "HIGH", notification: { channel_id: "absence_alerts" } },
        },
      }),
    });
    if (res.ok) {
      sent++;
    } else {
      const err = await res.text();
      // Phone uninstalled the app / token expired: forget it.
      if (err.includes("UNREGISTERED") || err.includes("NOT_FOUND") || err.includes("INVALID_ARGUMENT")) {
        await admin.from("device_tokens").delete().eq("token", t.token);
      }
    }
  }
  return json({ ok: true, sent });
});
