// Notificações push (Web Push). Tipos:
//  - "teste": manda para os aparelhos de quem chamou (botão em Configurações).
//  - "treinador": o treinador avisa o aluno de um treino novo (body.link_id); só vínculo ativo do próprio treinador.
//  - "anamnese": pedido do treinador (avisa o aluno) ou resposta do aluno (avisa o treinador); body.link_id e body.evento.
//  - "desafios": resultado das semanas de desafio que fecharam nos últimos 7 dias; só a função agendada chama
//    (segunda às 9h de Brasília, header x-cron-secret). Um aviso por pessoa, mesmo com vários desafios.
// Sem lembrete diário nem cobrança de treino (decisão do Andre, 21/10).
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex.: "mailto:contato@movoapp.com.br"). O segredo do agendamento fica no Vault (push_segredo_ok).
// Sem as chaves VAPID responde enviado:false (nada é mandado).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};
const APP = "https://app.movoapp.com.br/";

// --- Placar do desafio: mesma conta do app (desafioNormalizeRules / desafioContarLista / desafioStandings) ---
type Regras = { km: boolean; meta: number; pontos: number[]; bonusJuntos: number; maxPorDia: number; dias: number[] };
function regrasNorm(raw: Record<string, unknown> | null): Regras {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const meta = Math.min(7, Math.max(1, Math.round(Number(r.meta)) || 4));
  let pontos = Array.isArray(r.pontos) ? (r.pontos as unknown[]).map((n) => Math.round(Number(n)) || 0) : [0, 0, 1, 3, 5];
  while (pontos.length < meta + 1) pontos.push(pontos.length ? pontos[pontos.length - 1] : 0);
  pontos = pontos.slice(0, meta + 1);
  const d = Array.isArray(r.dias) ? Array.from(new Set((r.dias as unknown[]).map(Number).filter((n) => n >= 0 && n <= 6 && Number.isInteger(n)))).sort() : [];
  return {
    km: r.modo === "km", // desafio de distância (fase 5): placar = km de corrida da semana
    meta, pontos,
    bonusJuntos: Math.min(5, Math.max(0, Math.round(Number(r.bonusJuntos)) || 0)),
    maxPorDia: Math.min(3, Math.max(0, Math.round(Number(r.maxPorDia)) || 0)),
    dias: d.length === 0 || d.length === 7 ? [0, 1, 2, 3, 4, 5, 6] : d,
  };
}
const somaDias = (iso: string, n: number) => { const t = new Date(iso + "T12:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };
const diaSemana = (iso: string) => new Date(iso + "T12:00:00Z").getUTCDay();
type Ck = { user_id: string; date: string; tipo: string; label?: string | null; km?: number | null };
// Km do check-in: a coluna km ou o " · 5,2 km" do rótulo (igual desafioCheckinKm no app).
function kmDe(c: Ck) {
  const k = Number(c.km);
  if (k > 0) return k;
  const m = String(c.label || "").match(/ · (\d+(?:,\d+)?) km$/);
  return m ? parseFloat(m[1].replace(",", ".")) : 0;
}
type Jt = { date: string; from_user: string; to_user: string; status: string };
function contar(cks: Ck[], uid: string, ini: string, fim: string, r: Regras) {
  const vistos = new Set<string>(); const porDia: Record<string, number> = {};
  cks.forEach((c) => {
    if (c.user_id !== uid || c.date < ini || c.date > fim || r.dias.indexOf(diaSemana(c.date)) < 0) return;
    const k = `${c.date}|${c.tipo}`; if (vistos.has(k)) return; vistos.add(k);
    porDia[c.date] = (porDia[c.date] || 0) + 1;
  });
  return Object.keys(porDia).reduce((a, d) => a + (r.maxPorDia > 0 ? Math.min(r.maxPorDia, porDia[d]) : porDia[d]), 0);
}
// Resultado de uma semana fechada: pontos de cada um, vencedores e perdedores.
function semana(r: Regras, membros: string[], cks: Ck[], juntos: Jt[], ini: string, fim: string) {
  const tem = (uid: string, d: string) => r.dias.indexOf(diaSemana(d)) >= 0 && cks.some((c) => c.user_id === uid && c.date === d);
  const rows = membros.map((uid) => {
    if (r.km) {
      const minhas = cks.filter((c) => c.user_id === uid && c.date >= ini && c.date <= fim && r.dias.indexOf(diaSemana(c.date)) >= 0 && kmDe(c) > 0);
      return { uid, count: minhas.length, pts: Math.round(minhas.reduce((t, c) => t + kmDe(c), 0) * 10) / 10 };
    }
    const count = contar(cks, uid, ini, fim, r);
    const bonus = juntos.filter((t) => t.status === "confirmed" && t.date >= ini && t.date <= fim && (t.from_user === uid || t.to_user === uid) && tem(t.from_user, t.date) && tem(t.to_user, t.date)).length;
    return { uid, count, pts: r.pontos[Math.min(count, r.pontos.length - 1)] + bonus * r.bonusJuntos };
  });
  let winners: string[] = [], losers: string[] = [];
  if (rows.length >= 2) {
    const max = Math.max(...rows.map((x) => x.pts)), min = Math.min(...rows.map((x) => x.pts));
    if (max > min) { winners = rows.filter((x) => x.pts === max).map((x) => x.uid); losers = rows.filter((x) => x.pts === min).map((x) => x.uid); }
  }
  return { rows: rows.sort((a, b) => b.pts - a.pts || b.count - a.count), winners, losers };
}

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

    if (tipo === "desafios") {
      const { data: segOk } = await admin.rpc("push_segredo_ok", { p: req.headers.get("x-cron-secret") || "" });
      if (segOk !== true) return json({ ok: false, erro: "nao_autorizado" }, 401);
      const hoje = new Date(Date.now() - 3 * 3600000).toISOString().slice(0, 10); // dia em Brasília
      const { data: insc } = await admin.from("push_inscricoes").select("user_id,tipos");
      const comPush = new Set(((insc || []) as Insc[]).filter((i) => (i.tipos || {}).desafios !== false).map((i) => i.user_id));
      if (!comPush.size) return json({ ok: true, pessoas: 0 });
      const { data: chs } = await admin.from("challenges").select("id,nome,start_date,weeks,rules,stakes").lte("start_date", somaDias(hoje, -1));
      // Por pessoa: os resultados das semanas que fecharam entre hoje-7 e ontem.
      const porPessoa: Record<string, { ch: { id: string; nome: string }; num: number; idx: number; venceu: boolean; serie: number; fim: boolean; vencedor: string; pts: number; pos: number; empate: boolean; premio: boolean; ref: string; km: boolean }[]> = {};
      for (const ch of (chs || []) as { id: string; nome: string; start_date: string; weeks: number; rules: Record<string, unknown>; stakes: Record<string, unknown> }[]) {
        const fimDesafio = somaDias(ch.start_date, ch.weeks * 7 - 1);
        if (fimDesafio < somaDias(hoje, -7)) continue;
        const idxs: number[] = [];
        for (let i = 0; i < ch.weeks; i++) { const f = somaDias(ch.start_date, i * 7 + 6); if (f >= somaDias(hoje, -7) && f <= somaDias(hoje, -1)) idxs.push(i); }
        if (!idxs.length) continue;
        const { data: mem } = await admin.from("challenge_members").select("user_id").eq("challenge_id", ch.id);
        const membros = ((mem || []) as { user_id: string }[]).map((m) => m.user_id);
        if (membros.length < 2 || !membros.some((u) => comPush.has(u))) continue;
        // Sem a coluna km (fase5.sql não aplicado), lê sem ela; o km sai do rótulo.
        const ck1 = await admin.from("challenge_checkins").select("user_id,date,tipo,label,km").eq("challenge_id", ch.id);
        const cks: unknown[] | null = ck1.error ? (await admin.from("challenge_checkins").select("user_id,date,tipo,label").eq("challenge_id", ch.id)).data : ck1.data;
        const { data: jt } = await admin.from("challenge_together").select("date,from_user,to_user,status").eq("challenge_id", ch.id);
        const { data: nomes } = await admin.from("app_data").select("user_id,display_name").in("user_id", membros);
        const nomeDe = (uid: string) => { const n = ((nomes || []) as { user_id: string; display_name: string | null }[]).find((x) => x.user_id === uid); return (n && n.display_name && n.display_name.trim().split(" ")[0]) || "Alguém"; };
        const r = regrasNorm(ch.rules);
        const res = [];
        for (let i = 0; i <= Math.max(...idxs); i++) res.push(semana(r, membros, (cks || []) as Ck[], (jt || []) as Jt[], somaDias(ch.start_date, i * 7), somaDias(ch.start_date, i * 7 + 6)));
        for (const i of idxs) {
          const w = res[i];
          for (const uid of membros) {
            if (!comPush.has(uid)) continue;
            let serie = 0;
            for (let k = i; k >= 0 && res[k].winners.indexOf(uid) >= 0; k--) serie++;
            const row = w.rows.find((x) => x.uid === uid);
            const pos = w.rows.findIndex((x) => x.pts === (row ? row.pts : 0)) + 1;
            const v = w.winners[0];
            (porPessoa[uid] = porPessoa[uid] || []).push({
              ch: { id: ch.id, nome: ch.nome }, num: i + 1, idx: i, venceu: w.winners.indexOf(uid) >= 0, serie, fim: i === ch.weeks - 1,
              vencedor: v ? (w.winners.length > 1 ? w.winners.map(nomeDe).join(" e ") : nomeDe(v)) : "", pts: v ? (w.rows.find((x) => x.uid === v) || { pts: 0 }).pts : 0,
              pos, empate: !v, premio: !!(ch.stakes && (ch.stakes as Record<string, unknown>).semana), ref: `${ch.id}:${i + 1}`, km: r.km,
            });
          }
        }
      }
      let pessoas = 0, ok = 0;
      for (const [uid, itens] of Object.entries(porPessoa)) {
        // Não repete o que já foi avisado.
        const { data: ja } = await admin.from("push_envios").select("ref").eq("user_id", uid).eq("tipo", "desafios").in("ref", itens.map((x) => x.ref));
        const jaRefs = new Set(((ja || []) as { ref: string }[]).map((x) => x.ref));
        const novos = itens.filter((x) => !jaRefs.has(x.ref));
        if (!novos.length) continue;
        // Vitória primeiro: é o aviso que tem algo para compartilhar.
        const it = novos.find((x) => x.venceu) || novos[0];
        let msg;
        if (it.venceu) {
          msg = {
            // Título curto (o nome do desafio pode ser longo e cortar no iPhone); o nome vai no corpo.
            title: it.fim ? "🏆 Você venceu a última semana" : `🏆 Você venceu a semana ${it.num}`,
            body: it.serie > 1 ? `${it.ch.nome} · ${it.serie} semanas seguidas na frente. Toque para compartilhar.` : `${it.ch.nome} · Toque para compartilhar com o grupo.`,
          };
        } else if (novos.length > 1) {
          msg = { title: "Seus desafios fecharam a semana", body: "Veja quem venceu cada um." };
        } else if (it.empate) {
          msg = { title: `${it.ch.nome}: semana ${it.num} fechada`, body: it.premio ? "Semana empatada. Ninguém paga nada." : "Semana empatada." };
        } else {
          msg = { title: `${it.ch.nome}: semana ${it.num} fechada`, body: `${it.vencedor} venceu com ${it.km ? `${String(it.pts).replace(".", ",")} km` : `${it.pts} ponto${Math.abs(it.pts) === 1 ? "" : "s"}`}. Você ficou em ${it.pos}º.` };
        }
        const url = novos.length > 1 && !it.venceu ? `${APP}?desafios=1` : `${APP}?resultado=${it.ch.id}&semana=${it.idx}`;
        const res = await mandar(uid, "desafios", it.ref, { ...msg, url, tag: "desafios" });
        // Registra os outros refs da mesma pessoa para não avisar de novo.
        for (const x of novos) if (x.ref !== it.ref && res.aparelhos) await admin.from("push_envios").insert({ user_id: uid, tipo: "desafios", ref: x.ref, aparelhos: 0 });
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

    // Anamnese: "pedido" (o treinador pediu, avisa o aluno) ou "respondida" (o aluno respondeu, avisa o treinador).
    // Usa a categoria "treinador" das preferências. No máximo um aviso por pessoa e vínculo a cada 10 minutos.
    if (tipo === "anamnese") {
      const linkId = String(body.link_id || "");
      const evento = String(body.evento || "");
      const { data: l } = await admin.from("coach_links").select("id,coach_id,student_id,status").eq("id", linkId).maybeSingle();
      if (!l || l.status !== "ativo") return json({ ok: false, erro: "vinculo_invalido" }, 403);
      const { data: a } = await admin.from("coach_anamneses").select("respostas,respondida_em").eq("link_id", linkId).maybeSingle();
      if (!a) return json({ ok: false, erro: "sem_anamnese" }, 404);
      let para = "", msg: { title: string; body: string; tag: string };
      if (evento === "pedido" && l.coach_id === me) {
        const { data: p } = await admin.from("coach_profiles").select("nome_exibicao").eq("user_id", me).maybeSingle();
        const nome = String((p && p.nome_exibicao) || "Seu treinador").trim().split(" ")[0];
        para = l.student_id;
        msg = { title: `${nome} pediu um questionário de saúde`, body: "Leva uns 3 minutos. Abra o Movo para responder.", tag: `anamnese-${linkId}` };
      } else if (evento === "respondida" && l.student_id === me && a.respondida_em) {
        const { data: lk } = await admin.from("coach_links").select("student_label").eq("id", linkId).maybeSingle();
        const { data: ad } = await admin.from("app_data").select("display_name").eq("user_id", me).maybeSingle();
        const nome = String((ad && ad.display_name) || (lk && lk.student_label) || "Seu aluno").trim().split(" ")[0];
        const parq = Array.isArray(a.respostas && a.respostas.parq) ? a.respostas.parq : [];
        const nSim = parq.filter((x: unknown) => x === true).length;
        para = l.coach_id;
        msg = { title: `${nome} respondeu a anamnese`, body: nSim ? `${nSim} "sim" no PAR-Q. Veja antes do próximo treino.` : "Toque para ver as respostas.", tag: `anamnese-${linkId}` };
      } else return json({ ok: false, erro: "nao_autorizado" }, 403);
      const desde = new Date(Date.now() - 10 * 60000).toISOString();
      const { count } = await admin.from("push_envios").select("id", { count: "exact", head: true })
        .eq("user_id", para).eq("tipo", "treinador").eq("ref", `anamnese-${linkId}`).gte("criado_em", desde);
      if ((count || 0) > 0) return json({ ok: true, enviado: false, motivo: "recente" });
      const res = await mandar(para, "treinador", `anamnese-${linkId}`, msg);
      return json({ ok: true, enviado: res.ok > 0 });
    }

    return json({ ok: false, erro: "tipo_invalido" }, 400);
  } catch (e) {
    return json({ ok: false, erro: String(e) }, 500);
  }
});
