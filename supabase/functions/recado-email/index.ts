// Envia um recado do painel por e-mail (Resend), em lote, respeitando a cota dos recados (80/dia, 2.000/mês; ver recado_email.sql).
// Só admin: as RPCs admin_m_recado_email_* conferem is_movo_admin() com o token de quem chamou. Cada e-mail leva o link "sair da lista".
// Secrets: RESEND_API_KEY (obrigatória), FEEDBACK_FROM (ex.: "Movo <aviso@movoapp.com.br>"). Sem a chave não envia nem marca ninguém.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const esc = (s: string) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (o: unknown, s = 200) =>
    new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return json({ ok: false, erro: "email_nao_configurado", enviados: 0 });
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    });
    const { id } = await req.json();
    const { data: fila, error } = await sb.rpc("admin_m_recado_email_fila", { p_id: Number(id) });
    if (error) return json({ ok: false, erro: error.message }, /forbidden/.test(error.message) ? 403 : 400);
    const lote = (fila.lote || []) as { id: string; email: string; nome: string | null; token: string }[];
    if (!lote.length) return json({ ok: true, enviados: 0, pendentes: fila.pendentes, cota: fila.cota });

    const r = fila.recado;
    const from = Deno.env.get("FEEDBACK_FROM") || Deno.env.get("CONVITE_FROM") || "Movo <onboarding@resend.dev>";
    const temBotao = !!(r.botao_txt && r.botao_url);
    const url = temBotao ? r.botao_url : "https://app.movoapp.com.br";
    const botao = temBotao ? r.botao_txt : "Abrir o Movo";
    const msgs = lote.map((p) => {
      const sair = `https://movoapp.com.br/sair/?t=${p.token}`;
      return {
        from, to: [p.email], subject: r.titulo,
        headers: { "List-Unsubscribe": `<${sair}>` },
        html: `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.5;color:#14161A">` +
          `<p>${p.nome ? `Oi, ${esc(p.nome)}!` : "Oi!"}</p><p style="white-space:pre-wrap">${esc(r.texto)}</p>` +
          `<p><a href="${esc(url)}" style="display:inline-block;background:#C6F135;color:#14161A;padding:10px 18px;border-radius:10px;text-decoration:none;font-weight:700">${esc(botao)}</a></p>` +
          `<p style="color:#666;font-size:12px;margin-top:28px">Você recebe este e-mail porque tem conta no Movo. ` +
          `<a href="${sair}" style="color:#666">Não quero mais receber recados por e-mail</a>.</p></div>`,
        text: `${r.texto}\n\n${botao}: ${url}\n\nNão quer mais receber recados por e-mail? ${sair}`,
      };
    });

    // Lotes de até 100 (limite do /emails/batch). Só marca como enviado quem o Resend aceitou.
    const enviados: string[] = [];
    for (let i = 0; i < msgs.length; i += 100) {
      const resp = await fetch("https://api.resend.com/emails/batch", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(msgs.slice(i, i + 100)),
      });
      if (!resp.ok) {
        const det = await resp.text();
        if (enviados.length) await sb.rpc("admin_m_recado_email_ok", { p_id: Number(id), p_users: enviados });
        return json({ ok: false, erro: "resend_" + resp.status, detalhe: det.slice(0, 300), enviados: enviados.length }, 502);
      }
      lote.slice(i, i + 100).forEach((p) => enviados.push(p.id));
    }
    await sb.rpc("admin_m_recado_email_ok", { p_id: Number(id), p_users: enviados });
    return json({ ok: true, enviados: enviados.length, pendentes: fila.pendentes - enviados.length, cota: fila.cota - enviados.length });
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
