// Notificações push (Web Push). Tipos:
//  - "teste": manda para os aparelhos de quem chamou (botão em Configurações).
//  - "treinador": o treinador avisa o aluno de um treino novo (body.link_id); só vínculo ativo do próprio treinador.
//  - "lembrete": treino do dia para quem ainda não treinou; só a função agendada chama (header x-cron-secret).
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex.: "mailto:contato@movoapp.com.br"), PUSH_CRON_SECRET.
// Sem as chaves VAPID responde enviado:false (nada é mandado).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};
const APP = "https://app.movoapp.com.br/";

type Insc = { id: string; user_id: string; endpoint: string; p256dh: string; auth: string; tipos: Record<string, boolean> | null };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (o: unknown, s = 200) =>
    new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
    if (!pub || !priv) return json({ ok: true, enviado: false, motivo: "push_nao_configurado" });
    webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:contato@movoapp.com.br", pub, priv);
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const body = await req.json().catch(() => ({}));
    const tipo = String(body.tipo || "");

    // Manda uma mensagem para todos os aparelhos de uma pessoa (que aceitam esse tipo); apaga inscrições vencidas.
    async function mandar(userId: string, tipoMsg: string, ref: string, msg: { title: string; body: string; url?: string; tag?: string }) {
      const { data } = await admin.from("push_inscricoes").select("id,user_id,endpoint,p256dh,auth,tipos").eq("user_id", userId);
      const lista = ((data || []) as Insc[]).filter((i) => tipoMsg === "teste" || (i.tipos || {})[tipoMsg] !== false);
      let ok = 0;
      for (const i of lista) {
        try {
          await webpush.sendNotification({ endpoint: i.endpoint, keys: { p256dh: i.p256dh, auth: i.auth } },
            JSON.stringify({ title: msg.title, body: msg.body, url: msg.url || APP, tag: msg.tag || tipoMsg }), { TTL: 6 * 3600 });
          ok++;
          await admin.from("push_inscricoes").update({ ultimo_ok: new Date().toISOString(), falhas: 0 }).eq("id", i.id);
        } catch (e) {
          const st = (e as { statusCode?: number }).statusCode;
          if (st === 404 || st === 410) await admin.from("push_inscricoes").delete().eq("id", i.id);
          else await admin.from("push_inscricoes").update({ falhas: 1 }).eq("id", i.id);
        }
      }
      if (lista.length) await admin.from("push_envios").insert({ user_id: userId, tipo: tipoMsg, ref, aparelhos: ok });
      return { aparelhos: lista.length, ok };
    }

    if (tipo === "lembrete") {
      const segredo = Deno.env.get("PUSH_CRON_SECRET");
      if (!segredo || req.headers.get("x-cron-secret") !== segredo) return json({ ok: false, erro: "nao_autorizado" }, 401);
      const { data, error } = await admin.rpc("push_lembretes_hoje");
      if (error) return json({ ok: false, erro: error.message }, 400);
      let pessoas = 0, ok = 0;
      for (const r of (data || []) as { user_id: string; nome_treino: string }[]) {
        const nome = r.nome_treino && r.nome_treino !== "treino" ? r.nome_treino : "seu treino";
        const res = await mandar(r.user_id, "lembrete", new Date().toISOString().slice(0, 10), {
          title: "Treino de hoje", body: `Hoje tem ${nome} na sua agenda. Quando terminar, registre no Movo.`, tag: "lembrete",
        });
        pessoas++; ok += res.ok;
      }
      return json({ ok: true, pessoas, enviados: ok });
    }

    // Os outros tipos exigem a pessoa logada.
    const auth = req.headers.get("Authorization") || "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, erro: "nao_autenticado" }, 401);
    const me = u.user.id;

    if (tipo === "teste") {
      const res = await mandar(me, "teste", "", { title: "Movo", body: "Pronto: as notificações deste aparelho estão funcionando.", tag: "teste" });
      return json({ ok: true, enviado: res.ok > 0, ...res });
    }

    if (tipo === "treinador") {
      const linkId = String(body.link_id || "");
      const { data: l } = await admin.from("coach_links").select("id,coach_id,student_id,status").eq("id", linkId).maybeSingle();
      if (!l || l.coach_id !== me || l.status !== "ativo") return json({ ok: false, erro: "vinculo_invalido" }, 403);
      // No máximo um aviso por aluno a cada 10 minutos (vários envios seguidos viram um aviso só).
      const desde = new Date(Date.now() - 10 * 60000).toISOString();
      const { count } = await admin.from("push_envios").select("id", { count: "exact", head: true })
        .eq("user_id", l.student_id).eq("tipo", "treinador").gte("criado_em", desde);
      if ((count || 0) > 0) return json({ ok: true, enviado: false, motivo: "recente" });
      const { data: p } = await admin.from("coach_profiles").select("nome_exibicao").eq("user_id", me).maybeSingle();
      const nome = (p && p.nome_exibicao) || "Seu treinador";
      const res = await mandar(l.student_id, "treinador", linkId, {
        title: `${nome} mandou um treino novo`, body: "Abra o Movo para ver e aceitar.", tag: `treinador-${linkId}`,
      });
      return json({ ok: true, enviado: res.ok > 0 });
    }

    return json({ ok: false, erro: "tipo_invalido" }, 400);
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
