-- Painel de métricas, rodada 2: propriedades nos eventos, origem do cadastro, ativação/"aha", canal → 1º treino
-- e "quem usou voltou mais?". Requer admin_metricas.sql e admin_metricas_v2.sql. Seguro rodar de novo.

-- 1) Eventos com propriedades (ex.: treino_registrado { tipo, origem })
alter table public.app_events add column if not exists props jsonb;

-- 2) Origem do cadastro: uma linha por conta, gravada pelo próprio app (só a conta dona consegue inserir; ninguém lê de fora)
create table if not exists public.user_origem (
  user_id uuid primary key references auth.users(id) on delete cascade,
  src text,        -- utm_source do link (ex.: lp, lp-treinador)
  pos text,        -- posição do botão na landing
  convite text,    -- desafio | treinador | prof (quando entrou por convite)
  host text,
  criado_em timestamptz not null default now());
alter table public.user_origem enable row level security;
grant insert on public.user_origem to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_origem' and policyname = 'user_origem_insert_own') then
    create policy user_origem_insert_own on public.user_origem for insert to authenticated with check (auth.uid() = user_id);
  end if;
end $$;

-- 3) "Treinou" passa a incluir o evento único treino_registrado
create or replace function public._m_treino() returns text[]
language sql immutable as $$ select array['treino_registrado','treino_concluido','primeiro_registro','corrida_registrada_manual'] $$;

-- 4) Ativação e "aha moment", por semana de cadastro (só contas criadas desde 05/10/2026, quando os eventos começaram)
--    ativação: 1º treino em até 7 dias da criação da conta (só contas com 7+ dias)
--    aha: 2º dia de treino em até 7 dias depois do 1º (só quem treinou e já passaram 7 dias desde o 1º)
create or replace function public.admin_m_ativacao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex) and public._m_dia(created_at) >= date '2026-10-05'),
  t as (select e.user_id, public._m_dia(e.created_at) dia from app_events e join c on c.id = e.user_id where e.name = any(public._m_treino()) group by 1, 2),
  prim as (select c.id, c.sd, min(t.dia) primeiro from c join t on t.user_id = c.id group by c.id, c.sd),
  seg as (select p.id, min(t.dia) segundo from prim p join t on t.user_id = p.id and t.dia > p.primeiro group by p.id),
  f as (select c.id, date_trunc('week', c.sd)::date semana,
          (hoje >= c.sd + 7) el_a,
          (p.primeiro is not null and p.primeiro <= c.sd + 7) a1,
          (p.primeiro is not null and hoje >= p.primeiro + 7) el_b,
          (p.primeiro is not null and s.segundo is not null and s.segundo <= p.primeiro + 7) a2
        from c left join prim p on p.id = c.id left join seg s on s.id = c.id)
  select jsonb_build_object(
    'semanas', coalesce((select jsonb_agg(to_jsonb(w) order by w.semana desc) from (
        select semana::text semana, count(*) contas,
          count(*) filter (where el_a) el_a, count(*) filter (where el_a and a1) a1,
          count(*) filter (where el_b) el_b, count(*) filter (where el_b and a2) a2
        from f group by semana) w), '[]'::jsonb),
    'total', (select jsonb_build_object('contas', count(*),
        'el_a', count(*) filter (where el_a), 'a1', count(*) filter (where el_a and a1),
        'el_b', count(*) filter (where el_b), 'a2', count(*) filter (where el_b and a2)) from f)
  ) into r;
  return r;
end $$;

-- 5) Canal → 1º treino (origem gravada a partir da v177; contas anteriores aparecem como "sem registro")
create or replace function public.admin_m_canais() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (
    select u.id, public._m_dia(u.created_at) sd,
      case when o.user_id is null then 'sem registro'
           when o.convite is not null then 'convite: ' || o.convite
           when o.src is not null then o.src
           else 'direto' end canal
    from auth.users u left join user_origem o on o.user_id = u.id
    where u.id <> all(ex) and public._m_dia(u.created_at) >= date '2026-10-05'),
  t as (select e.user_id, min(public._m_dia(e.created_at)) primeiro from app_events e join c on c.id = e.user_id where e.name = any(public._m_treino()) group by 1),
  f as (select c.canal, c.id, (hoje >= c.sd + 7) el, (t.primeiro is not null) treinou, (t.primeiro is not null and t.primeiro <= c.sd + 7) a1
        from c left join t on t.user_id = c.id)
  select coalesce(jsonb_agg(to_jsonb(w) order by w.contas desc), '[]'::jsonb) into r from (
    select canal, count(*) contas, count(*) filter (where treinou) treinaram,
      count(*) filter (where el) el, count(*) filter (where el and a1) a1
    from f group by canal) w;
  return r;
end $$;

-- 6) Quem usou a funcionalidade voltou mais? Por evento: das pessoas que usaram (com 7+ dias desde o 1º uso), quantas abriram o app
--    nos 7 dias seguintes; comparado com quem não usou (com 7+ dias de conta). Só sinal de direção, nunca causa.
create or replace function public.admin_m_usoretorno() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex) and public._m_dia(created_at) >= date '2026-10-05'),
  o as (select distinct user_id, public._m_dia(opened_at) dia from app_opens),
  fu as (select e.user_id, e.name, min(public._m_dia(e.created_at)) fdia from app_events e join c on c.id = e.user_id
         where e.name !~ '^(aceite_|login_|onboarding_|onb_|tela_|logout|dominio_|estado_vazio_|modo_|semana_card_|catalogo_)' group by 1, 2),
  nm as (select name from fu group by name having count(*) >= 2),
  t as (
    select nm.name, fu.user_id, fu.fdia, true usou from nm join fu using (name) where fu.fdia + 7 <= hoje
    union all
    select nm.name, c.id, c.sd, false from nm cross join c
      where c.sd + 7 <= hoje and not exists (select 1 from fu where fu.user_id = c.id and fu.name = nm.name)),
  z as (select t.*, exists (select 1 from o where o.user_id = t.user_id and o.dia between t.fdia + 1 and t.fdia + 7) ret from t)
  select coalesce(jsonb_agg(to_jsonb(w) order by w.usou_n desc, w.name), '[]'::jsonb) into r from (
    select name,
      count(*) filter (where usou) usou_n, count(*) filter (where usou and ret) usou_ret,
      count(*) filter (where not usou) nao_n, count(*) filter (where not usou and ret) nao_ret
    from z group by name having count(*) filter (where usou) >= 2) w;
  return r;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_m_ativacao()','admin_m_canais()','admin_m_usoretorno()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
