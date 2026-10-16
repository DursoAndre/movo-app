// Manda por e-mail (Resend) um feedback recém-enviado. Opcional: sem a
// secret RESEND_API_KEY ela só responde ok sem enviar — o feedback já está
// salvo na tabela e aparece no painel admin.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const ADMIN = "ardurso@gmail.com";

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (o: unknown, s = 200) =>
    new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return json({ ok: true, enviado: false });
    const auth = req.headers.get("Authorization") || "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: auth } },
    });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, erro: "nao_autenticado" }, 401);
    const { id } = await req.json();
    // lê com o token da própria pessoa: a RLS só deixa ver o que ela mesma enviou
    const { data: f } = await sb.from("user_feedback").select("*").eq("id", id).maybeSingle();
    if (!f) return json({ ok: false, erro: "nao_encontrado" }, 404);
    const from = Deno.env.get("FEEDBACK_FROM") || "Movo <onboarding@resend.dev>";
    const to = Deno.env.get("FEEDBACK_TO") || ADMIN;
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from,
        to: [to],
        reply_to: f.contato ? u.user.email : undefined,
        subject: `[Movo] ${f.tipo}: ${String(f.mensagem).slice(0, 50)}`,
        html: `<p><b>${esc(f.tipo)}</b> · ${esc(u.user.email || "")} · app ${esc(f.versao || "?")}${f.contato ? "" : " · (não quer resposta)"}</p><p style="white-space:pre-wrap">${esc(f.mensagem)}</p>`,
      }),
    });
    return json({ ok: r.ok, enviado: r.ok });
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
