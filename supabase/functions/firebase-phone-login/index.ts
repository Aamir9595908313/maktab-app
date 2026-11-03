import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

// Real mobile-number login. The app proves phone ownership to Firebase
// (SMS OTP), then sends the resulting Firebase ID token here. This function:
//  1. verifies the token cryptographically against Google's public keys
//     (signature, issuer, audience = our Firebase project, expiry),
//  2. requires it to be a *phone* sign-in, recent, with a phone number,
//  3. finds (or creates, phone-confirmed) the matching Supabase user, so the
//     existing profile / role / RLS setup applies unchanged,
//  4. rotates that user's password to a random value nobody knows and signs
//     in with it server-side, returning only the resulting session.
// The password never leaves this function.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "faizerazamaktabapp";

const JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

function randomPassword(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);
  if (!FIREBASE_PROJECT_ID) return json({ ok: false, error: "Login is not configured yet." }, 500);

  let idToken = "";
  try {
    const body = await req.json();
    idToken = String(body?.idToken ?? "");
  } catch {
    return json({ ok: false, error: "Invalid request" }, 400);
  }
  if (!idToken) return json({ ok: false, error: "Missing token" }, 400);

  let claims: Record<string, unknown>;
  try {
    const { payload } = await jwtVerify(idToken, JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
      algorithms: ["RS256"],
    });
    claims = payload as Record<string, unknown>;
  } catch {
    return json({ ok: false, error: "Could not verify your phone number. Please try again." }, 401);
  }

  const firebase = (claims.firebase ?? {}) as Record<string, unknown>;
  const phoneClaim = String(claims.phone_number ?? "");
  const authTime = Number(claims.auth_time ?? 0);
  const nowSec = Math.floor(Date.now() / 1000);
  if (firebase.sign_in_provider !== "phone" || !/^\+91\d{10}$/.test(phoneClaim)) {
    return json({ ok: false, error: "Only Indian mobile numbers can sign in." }, 403);
  }
  // The OTP must have been verified just now, not an old token replayed.
  if (!authTime || nowSec - authTime > 600) {
    return json({ ok: false, error: "That OTP check is too old. Please request a new OTP." }, 401);
  }

  const phoneE164 = phoneClaim; // +91XXXXXXXXXX
  const phoneStored = phoneE164.replace("+", "");

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  let userId: string | null = null;
  const { data: found } = await admin.rpc("auth_user_id_by_phone", { p_phone: phoneStored });
  if (typeof found === "string") userId = found;

  if (!userId) {
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      phone: phoneE164,
      phone_confirm: true,
    });
    if (createErr || !created?.user) {
      // Lost a race with another request creating the same user.
      const { data: again } = await admin.rpc("auth_user_id_by_phone", { p_phone: phoneStored });
      if (typeof again !== "string") {
        return json({ ok: false, error: "Could not create your account. Please try again." }, 500);
      }
      userId = again;
    } else {
      userId = created.user.id;
    }
  }

  const password = randomPassword();
  const { error: updErr } = await admin.auth.admin.updateUserById(userId, {
    password,
    phone_confirm: true,
  });
  if (updErr) return json({ ok: false, error: "Could not sign you in. Please try again." }, 500);

  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signed, error: signErr } = await anon.auth.signInWithPassword({
    phone: phoneStored,
    password,
  });
  if (signErr || !signed?.session) {
    return json({ ok: false, error: "Could not sign you in. Please try again." }, 500);
  }

  return json({
    ok: true,
    access_token: signed.session.access_token,
    refresh_token: signed.session.refresh_token,
  });
});
