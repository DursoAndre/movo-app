// Avisa por e-mail (Resend): (a) treinador que recebeu pedido de um aluno; (b) pessoa que recebeu acesso a um relatório.
// Regras e limites ficam no banco (aviso_email_preparar). Sem RESEND_API_KEY responde enviado:false e NÃO consome o limite.
// Secrets: RESEND_API_KEY (obrigatória), CONVITE_FROM (opcional, ex.: "Movo <aviso@movoapp.com.br>"; domínio verificado no Resend).
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
    const { data, error } = await sb.rpc("aviso_email_preparar", { p_tipo: String(body.tipo || ""), p_ref: String(body.ref || "") });
    if (error) return json({ ok: false, erro: error.message }, 400);
    const from = Deno.env.get("CONVITE_FROM") || Deno.env.get("FEEDBACK_FROM") || "Movo <onboarding@resend.dev>";
    const app = "https://app.movoapp.com.br";
    const nome = esc(data.from_nome);
    const rodape = `<p style="color:#666;font-size:13px">Se você não conhece ${nome}, pode ignorar este e-mail. Não enviaremos outros sobre isso.</p>`;
    const msg = data.tipo === "pedido_treinador"
      ? { subject: `${data.from_nome} quer treinar com você no Movo`,
          html: `<p><b>${nome}</b> pediu para ser seu aluno no Movo.</p><p><a href="${app}">Abrir o Movo e responder</a><br><span style="color:#666">O pedido aparece no seu painel de alunos e vale por 14 dias.</span></p>${rodape}` }
      : { subject: `${data.from_nome} liberou os relatórios de treino para você no Movo`,
          html: `<p><b>${nome}</b> liberou o acesso aos relatórios de treino dele(a) para você.</p><p><a href="${app}">Abrir o Movo</a><br><span style="color:#666">Em Configurações, procure a lista de relatórios compartilhados com você.</span></p>${rodape}` };
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [data.to_email], subject: msg.subject, html: msg.html }),
    });
    return json({ ok: true, enviado: r.ok });
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
