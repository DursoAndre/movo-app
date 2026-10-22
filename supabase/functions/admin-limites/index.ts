// Painel › Saúde › "Limites do plano grátis": devolve o uso do Resend (API /usage: e-mails no dia e no mês, inclusive
// os de login, que saem pelo SMTP do Resend). Só para admin. Secret: RESEND_API_KEY. Se a chave não puder ler o uso
// (chave só de envio), responde resend:null e o painel mostra só o que o app registra.
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
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    });
    const { data: ehAdmin } = await sb.rpc("is_movo_admin");
    if (ehAdmin !== true) return json({ ok: false, erro: "forbidden" }, 403);

    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return json({ ok: true, resend: null, motivo: "sem_chave" });
    const r = await fetch("https://api.resend.com/usage", { headers: { Authorization: "Bearer " + key } });
    if (!r.ok) return json({ ok: true, resend: null, motivo: "resend_" + r.status });
    const u = await r.json();
    const e = u?.emails || {};
    const pega = (x: any) => x ? { usado: x.used ?? 0, limite: x.limit ?? null, renova: x.resets_at ?? null } : null;
    return json({ ok: true, resend: { dia: pega(e.daily), mes: pega(e.monthly) } });
  } catch (err) {
    return json({ ok: false, erro: String(err) }, 500);
  }
});
