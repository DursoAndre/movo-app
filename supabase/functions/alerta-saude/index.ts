// Alerta de saúde do Movo: roda a cada 15 min (pg_cron → pg_net) e manda e-mail (Resend) quando algo sai do normal:
// pico de erros no app, IA falhando, gasto da IA perto/acima do teto, banco quase cheio.
// Cada tipo de alerta tem um "descanso" para não lotar sua caixa de entrada.
// Autenticação: o banco manda o cabeçalho x-cron-secret (guardado no Vault) e a função confere via RPC alerta_segredo_ok.
// Secrets: RESEND_API_KEY (mesma do notificar-feedback), FEEDBACK_TO/FEEDBACK_FROM (opcionais).
// Deploy SEM verificação de JWT (quem chama é o banco, com o cabeçalho x-cron-secret).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ADMIN = "ardurso@gmail.com";
const LIMITE_BANCO_MB = 400; // plano grátis do Supabase: 500 MB
const DESCANSO_H: Record<string, number> = { erros: 3, ia_falhas: 3, banco: 24 };

function esc(s: string) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const enviado = req.headers.get("x-cron-secret") || "";
  const { data: autorizado } = enviado ? await sb.rpc("alerta_segredo_ok", { p: enviado }) : { data: false };
  if (autorizado !== true) return new Response("forbidden", { status: 403 });
  const { data: r, error } = await sb.rpc("saude_resumo");
  if (error || !r) {
    console.error("saude_resumo", error?.message);
    return new Response(JSON.stringify({ ok: false, erro: error?.message }), { status: 500 });
  }

  const alertas: { chave: string; titulo: string; html: string }[] = [];
  if (r.erros_30min >= 10) {
    const top = (r.erros_top || []).map((t: any) => `<li><b>${esc(t.context)}</b> — ${t.n}x · ${esc(t.exemplo || "")}</li>`).join("");
    alertas.push({ chave: "erros", titulo: `${r.erros_30min} erros no app em 30 min`, html: `<p>Mais erros que o normal (${r.erros_24h} nas últimas 24 h, ${r.erros_24h_antes} nas 24 h anteriores).</p><ul>${top}</ul>` });
  }
  if (r.ia_falhas_1h >= 3 && r.ia_falhas_1h / Math.max(1, r.ia_total_1h) >= 0.5) {
    alertas.push({ chave: "ia_falhas", titulo: `IA falhando: ${r.ia_falhas_1h} de ${r.ia_total_1h} chamadas na última hora`, html: `<p>Pode ser a API da Anthropic fora do ar, chave/crédito, ou um erro nas funções. Se precisar, desligue a IA em Admin → Controle da IA.</p>` });
  }
  const teto = Number(r.ia_teto_usd) || 0, hoje = Number(r.ia_hoje_usd) || 0;
  const dia = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
  if (teto > 0 && hoje >= teto) alertas.push({ chave: `ia100:${dia}`, titulo: `Teto diário da IA atingido (US$ ${hoje.toFixed(2)})`, html: `<p>A IA foi bloqueada para os usuários até amanhã. Para liberar, aumente o teto em Admin → Controle da IA.</p>` });
  else if (teto > 0 && hoje >= teto * 0.7) alertas.push({ chave: `ia70:${dia}`, titulo: `Gasto da IA em 70% do teto (US$ ${hoje.toFixed(2)} de ${teto.toFixed(2)})`, html: `<p>Se continuar nesse ritmo, o teto diário será atingido hoje.</p>` });
  if (r.banco_mb >= LIMITE_BANCO_MB) alertas.push({ chave: "banco", titulo: `Banco com ${r.banco_mb} MB (limite do plano grátis: 500 MB)`, html: `<p>Hora de limpar dados antigos ou subir de plano no Supabase.</p>` });

  const enviados: string[] = [];
  const key = Deno.env.get("RESEND_API_KEY");
  for (const a of alertas) {
    const base = a.chave.split(":")[0];
    const horas = a.chave.includes(":") ? 24 : DESCANSO_H[base] ?? 3;
    const cfg = `alerta:${a.chave}`;
    const { data: ult } = await sb.from("app_config").select("valor").eq("chave", cfg).maybeSingle();
    if (ult && Date.now() - Number(ult.valor) < horas * 3600_000) continue;
    if (key) {
      const resp = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: Deno.env.get("FEEDBACK_FROM") || "Movo <onboarding@resend.dev>",
          to: [Deno.env.get("FEEDBACK_TO") || ADMIN],
          subject: `[Movo • alerta] ${a.titulo}`,
          html: `<h3>${esc(a.titulo)}</h3>${a.html}<p style="color:#888">Ativos nas últimas 24 h: ${r.ativos_24h} · banco: ${r.banco_mb} MB</p>`,
        }),
      });
      if (!resp.ok) { console.error("resend", resp.status, (await resp.text()).slice(0, 200)); continue; }
    }
    await sb.from("app_config").upsert({ chave: cfg, valor: Date.now(), atualizado_em: new Date().toISOString() });
    enviados.push(a.chave);
  }
  return new Response(JSON.stringify({ ok: true, alertas: alertas.map((a) => a.chave), enviados }), { headers: { "Content-Type": "application/json" } });
});
