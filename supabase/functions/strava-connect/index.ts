// Supabase Edge Function: strava-connect
//
// Recebe o `code` do fluxo OAuth do Strava (redirect_uri aponta pro próprio
// app), troca por access_token/refresh_token usando o client_secret (que só
// existe aqui, nunca no app.js), e salva a conexão do usuário autenticado.
//
// Segurança: não usamos a service-role key. O client Supabase é criado
// repassando o header Authorization do próprio usuário, então o
// auth.uid() dentro das políticas de RLS já garante que cada usuário só
// consegue ler/escrever a própria linha em strava_connections.
//
// Deploy: via Supabase Dashboard → Edge Functions → New Function
// (nome: strava-connect) → colar este arquivo.
// Secrets necessários (Dashboard → Edge Functions → Secrets, ou
// `supabase secrets set`): STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ error: "not_authenticated" }, 401);
    }
    const userId = userData.user.id;

    const body = await req.json().catch(() => ({}));
    // Desconectar: revoga a autorização no Strava (o app some da lista de apps do atleta) e apaga a conexão.
    if (body?.action === "disconnect") {
      const cid = Deno.env.get("STRAVA_CLIENT_ID");
      const csec = Deno.env.get("STRAVA_CLIENT_SECRET");
      const { data: conn } = await supabase
        .from("strava_connections")
        .select("access_token, refresh_token, expires_at")
        .eq("user_id", userId)
        .maybeSingle();
      if (conn && cid && csec) {
        try {
          let tok = conn.access_token as string;
          if (!conn.expires_at || conn.expires_at * 1000 < Date.now() + 60000) {
            const r = await fetch("https://www.strava.com/oauth/token", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ client_id: cid, client_secret: csec, grant_type: "refresh_token", refresh_token: conn.refresh_token }),
            });
            if (r.ok) tok = (await r.json()).access_token ?? tok;
          }
          await fetch("https://www.strava.com/oauth/deauthorize", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({ access_token: tok }).toString(),
          });
        } catch (_e) { /* segue: apagar a conexão local é o que importa */ }
      }
      await supabase.from("strava_connections").delete().eq("user_id", userId);
      return json({ ok: true });
    }

    const code = body?.code;
    if (!code || typeof code !== "string") {
      return json({ error: "missing_code" }, 400);
    }

    const clientId = Deno.env.get("STRAVA_CLIENT_ID");
    const clientSecret = Deno.env.get("STRAVA_CLIENT_SECRET");
    if (!clientId || !clientSecret) {
      return json({ error: "server_not_configured" }, 500);
    }

    const tokenRes = await fetch("https://www.strava.com/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        grant_type: "authorization_code",
      }),
    });

    if (!tokenRes.ok) {
      const errText = await tokenRes.text().catch(() => "");
      return json({ error: "strava_token_exchange_failed", detail: errText }, 502);
    }

    const tokenData = await tokenRes.json();
    const {
      access_token: accessToken,
      refresh_token: refreshToken,
      expires_at: expiresAt,
      athlete,
    } = tokenData;

    if (!accessToken || !refreshToken || !expiresAt) {
      return json({ error: "unexpected_strava_response" }, 502);
    }

    const { error: upsertErr } = await supabase
      .from("strava_connections")
      .upsert(
        {
          user_id: userId,
          athlete_id: athlete?.id ?? null,
          access_token: accessToken,
          refresh_token: refreshToken,
          expires_at: expiresAt,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id" }
      );

    if (upsertErr) {
      return json({ error: "db_upsert_failed", detail: upsertErr.message }, 500);
    }

    return json({ ok: true });
  } catch (err) {
    return json({ error: "unexpected_error", detail: String(err) }, 500);
  }
});
