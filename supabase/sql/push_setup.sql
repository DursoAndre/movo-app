-- Notificações push (Web Push, v214). O app inscreve o aparelho (push_salvar) e a edge function `enviar-push`
-- manda: (a) "treino novo do treinador", chamado pelo app do treinador depois de enviar; (b) teste para o próprio
-- aparelho; (c) lembrete do treino do dia, pela função agendada no fim deste arquivo (DESLIGADA até o Andre aprovar).
-- Segredos da edge function: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:), PUSH_CRON_SECRET.
create table if not exists public.push_inscricoes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  ua text,
  tipos jsonb not null default '{"treinador": true, "lembrete": true}'::jsonb,
  criado_em timestamptz not null default now(),
  ultimo_ok timestamptz,
  falhas int not null default 0
);
create index if not exists push_inscricoes_user_idx on public.push_inscricoes (user_id);
alter table public.push_inscricoes enable row level security;
revoke all on public.push_inscricoes from public, anon, authenticated;

-- O que foi enviado (para não repetir o lembrete no mesmo dia e para medir).
create table if not exists public.push_envios (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null,
  ref text not null default '',
  aparelhos int not null default 0,
  criado_em timestamptz not null default now()
);
create index if not exists push_envios_user_idx on public.push_envios (user_id, tipo, criado_em desc);
alter table public.push_envios enable row level security;
revoke all on public.push_envios from public, anon, authenticated;

-- Inscreve (ou atualiza) este aparelho para a pessoa logada. Um aparelho só tem um dono: trocar de conta move a inscrição.
create or replace function public.push_salvar(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null, p_tipos jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not authenticated'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'inscrição inválida'; end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'inscrição inválida'; end if;
  insert into public.push_inscricoes (user_id, endpoint, p256dh, auth, ua, tipos)
  values (me, p_endpoint, p_p256dh, p_auth, left(p_ua, 200), coalesce(p_tipos, '{"treinador": true, "lembrete": true}'::jsonb))
  on conflict (endpoint) do update set user_id = me, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua,
    tipos = coalesce(p_tipos, public.push_inscricoes.tipos), falhas = 0;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.push_remover(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.push_inscricoes where endpoint = p_endpoint and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- Escolha do que receber (vale para todos os aparelhos da pessoa).
create or replace function public.push_tipos(p_tipos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.push_inscricoes set tipos = jsonb_build_object(
      'treinador', coalesce((p_tipos->>'treinador')::boolean, true),
      'lembrete', coalesce((p_tipos->>'lembrete')::boolean, true))
   where user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- Lembretes do dia: quem tem treino marcado hoje (semana fixa ou plano de semanas, sem descanso), ainda não
-- registrou nada hoje e não recebeu lembrete hoje. Só a edge function (service_role) chama.
create or replace function public.push_lembretes_hoje()
returns table (user_id uuid, nome_treino text)
language sql security definer set search_path = public as $$
  with hoje as (select public.coach_hoje() as d),
  alvos as (
    select distinct i.user_id from public.push_inscricoes i
     where coalesce((i.tipos->>'lembrete')::boolean, true)
  ),
  dados as (
    select al.user_id, a.schedule, a.planos, a.treinos, a.atividades, a.sessions, h.d,
           extract(dow from h.d)::int as dow
      from alvos al join public.app_data a on a.user_id = al.user_id cross join hoje h
  ),
  plano_hoje as (
    select dd.user_id,
           (select s->>'titulo' from jsonb_array_elements(case when jsonb_typeof(dd.planos) = 'array' then dd.planos else '[]'::jsonb end) p,
                   jsonb_array_elements(case when jsonb_typeof(p->'sessoes') = 'array' then p->'sessoes' else '[]'::jsonb end) s
             where s->>'data' = to_char(dd.d, 'YYYY-MM-DD') and coalesce(s->>'tipo', '') <> 'prova'
               and (p->>'encerradoEm' is null or p->>'encerradoEm' >= to_char(dd.d, 'YYYY-MM-DD'))
             limit 1) as titulo,
           exists (select 1 from jsonb_array_elements(case when jsonb_typeof(dd.planos) = 'array' then dd.planos else '[]'::jsonb end) p
                    where p->>'tipo' = 'semanas' and public.coach_date(p->>'inicio') <= dd.d
                      and dd.d <= coalesce(public.coach_date(p->>'encerradoEm'), public.coach_date(p->>'inicio') + (coalesce(public.coach_num(p->>'semanas'), 0) * 7 - 1)::int)) as cobre
      from dados dd
  ),
  fixo_hoje as (
    select dd.user_id,
           (select coalesce(
                     (select t->>'nome' from jsonb_array_elements(case when jsonb_typeof(dd.treinos) = 'array' then dd.treinos else '[]'::jsonb end) t where t->>'id' = it->>'id' and it->>'tipo' = 'treino' limit 1),
                     (select at->>'nome' from jsonb_array_elements(case when jsonb_typeof(dd.atividades) = 'array' then dd.atividades else '[]'::jsonb end) at where at->>'id' = it->>'id' and it->>'tipo' = 'atividade' limit 1))
              from jsonb_array_elements(case when jsonb_typeof(dd.schedule->(dd.dow::text)) = 'array' then dd.schedule->(dd.dow::text) else '[]'::jsonb end) it
             where not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(dd.atividades) = 'array' then dd.atividades else '[]'::jsonb end) at
                                where at->>'id' = it->>'id' and it->>'tipo' = 'atividade' and coalesce((at->>'descanso')::boolean, false))
             limit 1) as nome
      from dados dd
  )
  select dd.user_id, coalesce(ph.titulo, case when ph.cobre then null else fh.nome end, 'treino')
    from dados dd
    join plano_hoje ph on ph.user_id = dd.user_id
    join fixo_hoje fh on fh.user_id = dd.user_id
   where (ph.titulo is not null or (fh.nome is not null and not ph.cobre))
     and not public.coach_day_done(dd.sessions -> to_char(dd.d, 'YYYY-MM-DD'))
     and not exists (select 1 from public.push_envios e where e.user_id = dd.user_id and e.tipo = 'lembrete'
                      and e.criado_em > (dd.d::timestamp at time zone 'America/Sao_Paulo'));
$$;
revoke all on function public.push_lembretes_hoje() from public, anon, authenticated;

-- Função agendada (NÃO criada: depende da aprovação do Andre sobre frequência e custo).
-- Uma vez por dia às 18h de Brasília (21h UTC). Antes, guardar no Vault: push_cron_secret e project_url.
-- select cron.schedule('push-lembrete-diario', '0 21 * * *', $c$
--   select net.http_post(
--     url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/enviar-push',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--       'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
--     body := '{"tipo":"lembrete"}'::jsonb);
-- $c$);
