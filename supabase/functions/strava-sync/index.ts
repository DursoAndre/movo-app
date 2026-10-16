// Supabase Edge Function: strava-sync
//
// Busca atividades novas do Strava (desde o último sync, ou dos últimos 30
// dias no primeiro sync) e mescla elas nos dados do usuário em `app_data`
// (mesma tabela/linha usada pelo resto do app), criando/achando a atividade
// correspondente e marcando o dia como "fui" + comentário + carga (duração
// e RPE, quando o Strava reportar "esforço percebido").
//
// Segurança: mesmo padrão do strava-connect — client Supabase criado com o
// Authorization do próprio usuário, sem service-role key. RLS garante que
// cada usuário só mexe nos próprios dados.
//
// Deploy: via Supabase Dashboard → Edge Functions → New Function
// (nome: strava-sync) → colar este arquivo. Usa os mesmos secrets
// STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET (pra poder renovar o token).
//
// Limitação conhecida e aceita: busca só as primeiras 100 atividades da
// janela (sem paginação). Suficiente pro uso de "sincronizar de vez em
// quando" via botão manual.

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

// Strava sport_type -> nome em PT-BR pra virar "atividade" no app. Esportes
// fora dessa lista caem no nome em inglês que o próprio Strava manda
// (findOrCreateAtividade abaixo já trata isso via "|| sportType").
const SPORT_LABELS: Record<string, string> = {
  Run: "Corrida",
  TrailRun: "Corrida (trilha)",
  Ride: "Pedalada",
  MountainBikeRide: "Pedalada (MTB)",
  Swim: "Natação",
  Walk: "Caminhada",
  Hike: "Trilha (caminhada)",
  WeightTraining: "Musculação (Strava)",
  Workout: "Treino (Strava)",
  Crossfit: "CrossFit",
  Yoga: "Yoga",
  Pilates: "Pilates",
  Rowing: "Remo",
  Soccer: "Futebol",
  Volleyball: "Vôlei",
  BeachVolleyball: "Vôlei de praia",
  Basketball: "Basquete",
  Tennis: "Tênis",
  RockClimbing: "Escalada",
  Hyrox: "Hyrox",
};

function slugify(s: string) {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

function itemKey(tipo: string, id: string) {
  return `${tipo}:${id}`;
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

    const { data: conn, error: connErr } = await supabase
      .from("strava_connections")
      .select("*")
      .eq("user_id", userId)
      .maybeSingle();

    if (connErr) return json({ error: "db_read_failed", detail: connErr.message }, 500);
    if (!conn) return json({ error: "not_connected" }, 400);

    const clientId = Deno.env.get("STRAVA_CLIENT_ID");
    const clientSecret = Deno.env.get("STRAVA_CLIENT_SECRET");
    if (!clientId || !clientSecret) {
      return json({ error: "server_not_configured" }, 500);
    }

    let accessToken = conn.access_token as string;
    let refreshToken = conn.refresh_token as string;
    let expiresAt = conn.expires_at as number;

    // Renova o token se estiver vencido (ou vencendo em menos de 60s).
    const nowSec = Math.floor(Date.now() / 1000);
    if (expiresAt <= nowSec + 60) {
      const refreshRes = await fetch("https://www.strava.com/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          client_id: clientId,
          client_secret: clientSecret,
          refresh_token: refreshToken,
          grant_type: "refresh_token",
        }),
      });
      if (!refreshRes.ok) {
        const errText = await refreshRes.text().catch(() => "");
        return json({ error: "strava_refresh_failed", detail: errText }, 502);
      }
      const refreshData = await refreshRes.json();
      accessToken = refreshData.access_token;
      refreshToken = refreshData.refresh_token;
      expiresAt = refreshData.expires_at;

      await supabase
        .from("strava_connections")
        .update({ access_token: accessToken, refresh_token: refreshToken, expires_at: expiresAt })
        .eq("user_id", userId);
    }

    const after = conn.last_sync_at
      ? Math.floor(new Date(conn.last_sync_at).getTime() / 1000)
      : nowSec - 30 * 24 * 60 * 60;

    const actRes = await fetch(
      `https://www.strava.com/api/v3/athlete/activities?after=${after}&per_page=100`,
      { headers: { Authorization: `Bearer ${accessToken}` } }
    );
    if (!actRes.ok) {
      const errText = await actRes.text().catch(() => "");
      return json({ error: "strava_activities_failed", detail: errText }, 502);
    }
    const activities: any[] = await actRes.json();

    const syncedIds: number[] = Array.isArray(conn.synced_activity_ids)
      ? conn.synced_activity_ids
      : [];
    const syncedSet = new Set(syncedIds);
    const newActivities = activities.filter((a) => !syncedSet.has(a.id));

    if (newActivities.length === 0) {
      await supabase
        .from("strava_connections")
        .update({ last_sync_at: new Date().toISOString() })
        .eq("user_id", userId);
      return json({ ok: true, imported: 0 });
    }

    // Carrega os dados atuais do app pra mesclar. `app_data` guarda uma
    // linha por usuário com colunas soltas (treinos/atividades/schedule/
    // sessions), não um único JSONB — mesmo formato usado pelo resto do app.
    const { data: appRow, error: appErr } = await supabase
      .from("app_data")
      .select("*")
      .eq("user_id", userId)
      .maybeSingle();
    if (appErr) return json({ error: "db_read_failed", detail: appErr.message }, 500);

    const atividades: any[] = Array.isArray(appRow?.atividades) ? appRow.atividades : [];
    const sessions: Record<string, any> = appRow?.sessions && typeof appRow.sessions === "object"
      ? appRow.sessions
      : {};

    function findOrCreateAtividade(sportType: string) {
      const label = SPORT_LABELS[sportType] || sportType;
      const id = "strava-" + slugify(sportType);
      let existing = atividades.find((a) => a.id === id);
      if (!existing) {
        existing = { id, nome: label };
        atividades.push(existing);
      }
      return existing;
    }

    let imported = 0;

    for (const activity of newActivities) {
      const sportType = activity.sport_type || activity.type || "Workout";
      const startDate = activity.start_date_local || activity.start_date;
      if (!startDate) continue;
      const date = startDate.slice(0, 10); // YYYY-MM-DD

      if (!sessions[date]) {
        sessions[date] = { log: {}, extras: [], removed: [], cargas: {} };
      }
      const session = sessions[date];
      if (!session.log) session.log = {};
      if (!session.extras) session.extras = [];
      if (!session.cargas) session.cargas = {};

      // Corrida já registrada à mão no mesmo dia (distância ou duração parecidas): não duplica.
      if (["Run", "TrailRun", "VirtualRun"].includes(sportType)) {
        const kmS = activity.distance ? activity.distance / 1000 : 0;
        const minS = activity.moving_time ? activity.moving_time / 60 : 0;
        const perto = (a: number, b: number) => a > 0 && b > 0 && Math.abs(a - b) / Math.max(a, b) <= 0.15;
        const jaManual = Object.entries(session.cargas).some(([k, c]: [string, any]) =>
          /corrida/.test(k) && !k.startsWith("atividade:strava-") && c && (perto(Number(c.distanciaKm) || 0, kmS) || perto(Number(c.duracaoMin) || 0, minS)));
        if (jaManual) {
          syncedSet.add(activity.id);
          continue;
        }
      }

      const ativ = findOrCreateAtividade(sportType);
      const key = itemKey("atividade", ativ.id);

      const distanceKm = activity.distance ? (activity.distance / 1000).toFixed(1) : null;
      const durMin = activity.moving_time ? Math.round(activity.moving_time / 60) : null;
      const parts = [`Importado do Strava — ${activity.name || sportType}`];
      if (distanceKm) parts.push(`${distanceKm} km`);
      if (durMin) parts.push(`${durMin} min`);
      const novoComentario = parts.join(" · ");

      const existingLog = session.log[key];
      const comentarioAnterior = existingLog?.comentario ? existingLog.comentario + "\n" : "";
      session.log[key] = {
        status: "fui",
        comentario: comentarioAnterior + novoComentario,
      };

      const alreadyExtra = session.extras.some(
        (e: any) => e.tipo === "atividade" && e.id === ativ.id
      );
      if (!alreadyExtra) {
        session.extras.push({ tipo: "atividade", id: ativ.id });
      }

      const rpeRaw = activity.perceived_exertion;
      if (durMin || typeof rpeRaw === "number") {
        const prevCarga = session.cargas[key] || {};
        const novaDuracao = (prevCarga.duracaoMin || 0) + (durMin || 0);
        const novoRpe =
          typeof rpeRaw === "number"
            ? Math.max(prevCarga.rpe || 0, rpeRaw)
            : prevCarga.rpe;
        session.cargas[key] = {
          ...prevCarga,
          duracaoMin: novaDuracao,
          ...(novoRpe !== undefined ? { rpe: novoRpe } : {}),
          updatedAt: new Date().toISOString(),
        };
      }

      // Distância estruturada (km), usada pelos Desafios pra regra de "5 km ou mais".
      if (activity.distance) {
        const prevCarga2 = session.cargas[key] || {};
        session.cargas[key] = {
          ...prevCarga2,
          distanciaKm: Math.round(((prevCarga2.distanciaKm || 0) + activity.distance / 1000) * 10) / 10,
        };
      }

      syncedSet.add(activity.id);
      imported++;
    }

    const { error: updateErr } = appRow
      ? await supabase
          .from("app_data")
          .update({ atividades, sessions, updated_at: new Date().toISOString() })
          .eq("user_id", userId)
      : await supabase
          .from("app_data")
          .insert({ user_id: userId, atividades, sessions, updated_at: new Date().toISOString() });
    if (updateErr) return json({ error: "db_update_failed", detail: updateErr.message }, 500);

    await supabase
      .from("strava_connections")
      .update({
        last_sync_at: new Date().toISOString(),
        synced_activity_ids: Array.from(syncedSet),
      })
      .eq("user_id", userId);

    return json({ ok: true, imported });
  } catch (err) {
    return json({ error: "unexpected_error", detail: String(err) }, 500);
  }
});
