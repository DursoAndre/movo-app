// Painel › ficha da conta › "Apagar a conta a pedido" (decisão do Andre, 20/10/2026): apaga por completo, como a própria pessoa faria no app.
// 1) confere que quem chama é admin, que o e-mail digitado é o da conta e que a conta não é de admin;
// 2) revoga o acesso do Movo no Strava da pessoa (deauthorize); 3) apaga a foto (avatars/<id>/a.jpg);
// 4) chama admin_m_conta_apagar com o token de quem chamou (confere de novo, grava no Registro e roda delete_my_account).
// A service role só é usada para ler o token do Strava, ler o e-mail da conta e apagar a foto. Secrets: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (o: unknown, s = 200) =>
    new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const sb = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    });
    const { data: ehAdmin } = await sb.rpc("is_movo_admin");
    if (ehAdmin !== true) return json({ ok: false, erro: "forbidden" }, 403);

    const adm = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { user, email } = await req.json();
    const { data: alvo } = await adm.auth.admin.getUserById(String(user || ""));
    if (!alvo?.user) return json({ ok: false, erro: "conta_nao_encontrada" }, 404);
    if (String(email || "").trim().toLowerCase() !== String(alvo.user.email || "").toLowerCase()) return json({ ok: false, erro: "email_nao_confere" }, 400);
    const { data: alvoAdmin } = await adm.rpc("movo_admin_uid", { p_uid: alvo.user.id });
    if (alvoAdmin === true) return json({ ok: false, erro: "nao_pode_apagar_admin" }, 400);

    const passos: Record<string, string> = {};
    const { data: conn } = await adm.from("strava_connections").select("access_token, refresh_token, expires_at").eq("user_id", alvo.user.id).maybeSingle();
    if (conn) {
      try {
        let tok = conn.access_token as string;
        const cid = Deno.env.get("STRAVA_CLIENT_ID"), csec = Deno.env.get("STRAVA_CLIENT_SECRET");
        if (cid && csec && (!conn.expires_at || conn.expires_at * 1000 < Date.now() + 60000)) {
          const r = await fetch("https://www.strava.com/oauth/token", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ client_id: cid, client_secret: csec, grant_type: "refresh_token", refresh_token: conn.refresh_token }),
          });
          if (r.ok) tok = (await r.json()).access_token ?? tok;
        }
        const d = await fetch("https://www.strava.com/oauth/deauthorize", {
          method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ access_token: tok }).toString(),
        });
        passos.strava = d.ok ? "desconectado" : "falhou_" + d.status;
      } catch (_e) { passos.strava = "falhou"; }
    } else passos.strava = "nao_tinha";
    const { error: fotoErr } = await adm.storage.from("avatars").remove([`${alvo.user.id}/a.jpg`]);
    passos.foto = fotoErr ? "falhou" : "ok";

    const { error } = await sb.rpc("admin_m_conta_apagar", { p_user: alvo.user.id, p_email: alvo.user.email });
    if (error) return json({ ok: false, erro: error.message, passos }, 400);
    return json({ ok: true, passos });
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
