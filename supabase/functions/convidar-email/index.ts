// Manda por e-mail (Resend) o convite de desafio: aviso a amigo convidado pela lista, ou convite a quem não tem conta.
// Regras, limites e quem pode receber ficam no banco (convite_email_preparar). Sem RESEND_API_KEY responde enviado:false
// e NÃO consome o limite. Secrets: RESEND_API_KEY (obrigatória), CONVITE_FROM (opcional, ex.: "Movo <convite@movoapp.com.br>";
// o domínio precisa estar verificado no Resend, senão só chega ao dono da conta Resend).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const esc = (s: string) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (o: unknown, s = 200) =>
    new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return json({ ok: true, enviado: false, motivo: "email_nao_configurado" });
    const auth = req.headers.get("Authorization") || "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, erro: "nao_autenticado" }, 401);
    const body = await req.json();
    const { data, error } = await sb.rpc("convite_email_preparar", {
      p_id: body.challenge_id,
      p_user_ids: Array.isArray(body.user_ids) ? body.user_ids : null,
      p_email: typeof body.email === "string" ? body.email : null,
    });
    if (error) return json({ ok: false, erro: error.message }, 400);
    const link = `https://movoapp.com.br/convite/?desafio=${encodeURIComponent(data.code)}`;
    const from = Deno.env.get("CONVITE_FROM") || Deno.env.get("FEEDBACK_FROM") || "Movo <onboarding@resend.dev>";
    let enviados = 0;
    for (const t of data.targets as { email: string }[]) {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from,
          to: [t.email],
          subject: `${data.from_nome} te chamou pro desafio "${data.nome}" no Movo`,
          html: `<p><b>${esc(data.from_nome)}</b> te chamou pra um desafio de treino no Movo: <b>${esc(data.nome)}</b>.</p>` +
            `<p><a href="${link}">Ver o desafio e entrar</a><br><span style="color:#666">Se o botão não abrir, copie: ${link}</span></p>` +
            `<p style="color:#666;font-size:13px">Você só entra se quiser. Se não conhece ${esc(data.from_nome)}, pode ignorar este e-mail — não enviaremos outros.</p>`,
        }),
      });
      if (r.ok) enviados++;
    }
    return json({ ok: true, enviado: enviados > 0, enviados });
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
