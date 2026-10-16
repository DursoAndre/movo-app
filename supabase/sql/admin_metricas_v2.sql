-- Painel de métricas, rodada 1: "treino" com uma definição só, exclui você e contas de teste, janelas fechadas,
-- funil só com contas novas (eventos existem desde 05/10/2026) e card "pronto para redirecionar?".
-- Requer admin_metricas.sql (funções _m_dia, _m_site). Seguro rodar de novo.

-- Contas que não entram nas métricas (você e testes). Para incluir outra: edite a lista em app_config 'metricas_excluir'.
insert into public.app_config(chave, valor) values ('metricas_excluir', '["ardurso@gmail.com"]'::jsonb)
on conflict (chave) do nothing;

create or replace function public._m_excl() returns uuid[]
language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(u.id), '{}'::uuid[]) from auth.users u
  where lower(u.email) in (select lower(x) from jsonb_array_elements_text(coalesce((select valor from public.app_config where chave = 'metricas_excluir'), '[]'::jsonb)) x) $$;

-- "Treinou" = qualquer um destes eventos (academia, 1º registro, corrida manual)
create or replace function public._m_treino() returns text[]
language sql immutable as $$ select array['treino_concluido','primeiro_registro','corrida_registrada_manual'] $$;

-- Visão geral
create or replace function public.admin_m_geral() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with a as (select user_id, public._m_dia(opened_at) dia from app_opens where user_id <> all(ex)),
  v as (select e.user_id, public._m_dia(e.created_at) dia from app_events e where e.name = any(public._m_treino()) and e.user_id <> all(ex)),
  d as (select dia, count(distinct user_id) p from a group by dia)
  select jsonb_build_object(
    'excluidas', coalesce(array_length(ex,1),0),
    'contas', (select count(*) from auth.users where id <> all(ex)),
    'novas_7d', (select count(*) from auth.users where id <> all(ex) and public._m_dia(created_at) >= hoje - 6),
    'novas_hoje', (select count(*) from auth.users where id <> all(ex) and public._m_dia(created_at) = hoje),
    'dau', (select count(distinct user_id) from a where dia = hoje),
    'dau_ontem', (select count(distinct user_id) from a where dia = hoje - 1),
    'dau_media_7d', (select coalesce(round(avg(p)::numeric, 1), 0) from d where dia between hoje - 7 and hoje - 1),
    'wau', (select count(distinct user_id) from a where dia >= hoje - 6),
    'mau', (select count(distinct user_id) from a where dia >= hoje - 29),
    'abriram_algum_dia', (select count(distinct user_id) from a),
    'treinaram_7d', (select count(distinct user_id) from v where dia >= hoje - 6),
    'treinaram_30d', (select count(distinct user_id) from v where dia >= hoje - 29),
    'dois_dias_7d', (select count(*) from (select user_id from v where dia >= hoje - 6 group by user_id having count(distinct dia) >= 2) q),
    'com_treino', (select count(distinct user_id) from v),
    'instalado_7d', (select count(distinct user_id) from app_opens where user_id <> all(ex) and instalado is true and public._m_dia(opened_at) >= hoje - 6),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', g::date::text, 'pessoas', coalesce(x.p,0), 'treinaram', coalesce(t.p,0), 'novas', coalesce(n.c,0)) order by g), '[]'::jsonb)
      from generate_series(hoje - 29, hoje, interval '1 day') gs(g)
      left join d x on x.dia = g::date
      left join (select dia, count(distinct user_id) p from v group by dia) t on t.dia = g::date
      left join (select public._m_dia(created_at) dia, count(*) c from auth.users where id <> all(ex) group by 1) n on n.dia = g::date)
  ) into r;
  return r;
end $$;

-- Retenção: D1 = dia seguinte; D7 = dias 7 a 13; D30 = dias 28 a 34 (janela fechada). Só conta quem já completou a janela.
create or replace function public.admin_m_retencao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with u as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex)),
  f as (
    select u.id, u.sd, date_trunc('week', u.sd)::date semana,
      (hoje >= u.sd + 1) el1, (hoje >= u.sd + 13) el7, (hoje >= u.sd + 34) el30,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) = u.sd + 1) d1,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) between u.sd + 7 and u.sd + 13) d7,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) between u.sd + 28 and u.sd + 34) d30
    from u)
  select jsonb_build_object(
    'semanas', coalesce((select jsonb_agg(to_jsonb(w) order by w.semana desc) from (
        select semana::text semana, count(*) cadastros,
          count(*) filter (where el1) el1, count(*) filter (where el1 and d1) d1,
          count(*) filter (where el7) el7, count(*) filter (where el7 and d7) d7,
          count(*) filter (where el30) el30, count(*) filter (where el30 and d30) d30
        from f group by semana) w), '[]'::jsonb),
    'total', (select jsonb_build_object('cadastros', count(*),
        'el1', count(*) filter (where el1), 'd1', count(*) filter (where el1 and d1),
        'el7', count(*) filter (where el7), 'd7', count(*) filter (where el7 and d7),
        'el30', count(*) filter (where el30), 'd30', count(*) filter (where el30 and d30)) from f)
  ) into r;
  return r;
end $$;

-- Funil: só contas criadas a partir de 05/10/2026, quando os eventos começaram), todas as etapas sobre o mesmo grupo
create or replace function public.admin_m_funil() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); p_desde date := date '2026-10-05'; r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex) and public._m_dia(created_at) >= p_desde),
  ev as (select distinct e.user_id, e.name from app_events e join c on c.id = e.user_id),
  tr as (select e.user_id, count(distinct public._m_dia(e.created_at)) dias from app_events e join c on c.id = e.user_id where e.name = any(public._m_treino()) group by e.user_id)
  select jsonb_build_object('desde', p_desde::text, 'itens', jsonb_build_array(
    jsonb_build_object('etapa','Criaram conta','n',(select count(*) from c)),
    jsonb_build_object('etapa','Abriram o app','n',(select count(distinct o.user_id) from app_opens o join c on c.id = o.user_id)),
    jsonb_build_object('etapa','Aceitaram os termos','n',(select count(*) from ev where name='aceite_registrado')),
    jsonb_build_object('etapa','Começaram o onboarding','n',(select count(*) from ev where name='onboarding_iniciado')),
    jsonb_build_object('etapa','Concluíram o onboarding','n',(select count(*) from ev where name='onboarding_concluido')),
    jsonb_build_object('etapa','Registraram o 1º treino','n',(select count(*) from tr)),
    jsonb_build_object('etapa','Treinaram em 2 dias ou mais','n',(select count(*) from tr where dias >= 2)),
    jsonb_build_object('etapa','Abriram de novo após 7+ dias (só quem tem 7+ dias de conta)',
      'n',(select count(distinct c.id) from c join app_opens o on o.user_id = c.id and public._m_dia(o.opened_at) >= c.sd + 7 where hoje >= c.sd + 7),
      'base',(select count(*) from c where hoje >= c.sd + 7))
  )) into r;
  return r;
end $$;

-- Uso por funcionalidade: devolve os dois denominadores (quem abriu e quem treinou no período)
create or replace function public.admin_m_funcoes(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 365)); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'ativos_7d', (select count(distinct user_id) from app_opens where user_id <> all(ex) and public._m_dia(opened_at) >= hoje - 6),
    'ativos_periodo', (select count(distinct user_id) from app_opens where user_id <> all(ex) and public._m_dia(opened_at) >= hoje - (d - 1)),
    'treinaram_periodo', (select count(distinct user_id) from app_events where user_id <> all(ex) and name = any(public._m_treino()) and public._m_dia(created_at) >= hoje - (d - 1)),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v, 'pessoas_7d', p7, 'ultima', ult::text) order by p desc, v desc)
      from (select name, count(distinct user_id) p, count(*) v,
              count(distinct user_id) filter (where public._m_dia(created_at) >= hoje - 6) p7,
              max(public._m_dia(created_at)) ult
            from app_events where user_id <> all(ex) and public._m_dia(created_at) >= hoje - (d - 1) group by name) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Convites e landing
create or replace function public.admin_m_convites(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare d int := greatest(1, least(p_dias, 365)); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v) order by name)
      from (select name, count(distinct user_id) p, count(*) v from app_events
            where user_id <> all(ex)
              and name in ('convite_whatsapp','desafio_criado','desafio_cartao_compartilhado','desafio_entrou','desafio_aplauso')
              and public._m_dia(created_at) >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'landing', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc)
      from (select name, sum(n)::int n from lp_events where day >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'origens', coalesce((select jsonb_agg(jsonb_build_object('src', src, 'n', n) order by n desc)
      from (select coalesce(nullif(src,''),'(direto)') src, sum(n)::int n from lp_events
            where name = 'view' and day >= public._m_dia(now()) - (d - 1) group by 1 limit 12) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Domínio: gráfico por dia e "pronto para redirecionar?"
-- Pronto = ninguém que abriu o endereço antigo nos últimos 30 dias deixou de abrir o novo (nenhuma abertura no novo, nunca).
create or replace function public.admin_m_dominio(p_dias integer default 14) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 60)); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with o as (select user_id, opened_at, versao, host, public._m_dia(opened_at) dia, public._m_site(host, versao) site
             from app_opens where user_id <> all(ex)),
  ult as (select distinct on (user_id) user_id, opened_at, versao, site from o where dia >= hoje - 29 order by user_id, opened_at desc),
  pend as (select user_id from o where site = 'antigo' and dia >= hoje - 29
           except select user_id from o where site = 'novo'),
  lista as (
    select u.email, l.opened_at ult, l.versao, l.site,
      (l.versao is null or (l.versao ~ '^v[0-9]+$' and substring(l.versao from 2)::int < 163)) sem_aviso,
      (select count(distinct dia) from o where o.user_id = l.user_id and o.dia >= hoje - 13) dias,
      (l.user_id in (select user_id from pend)) sem_novo
    from ult l join auth.users u on u.id = l.user_id where l.site = 'antigo' or l.user_id in (select user_id from pend))
  select jsonb_build_object(
    'host_desde', (select min(opened_at) from o where host is not null),
    'serie', coalesce((select jsonb_agg(jsonb_build_object('dia', dia::text, 'site', site, 'pessoas', p) order by dia, site)
      from (select dia, site, count(distinct user_id) p from o where dia >= hoje - (d - 1) group by 1,2) q), '[]'::jsonb),
    'hoje_antigo', (select count(distinct user_id) from o where dia = hoje and site = 'antigo'),
    'hoje_novo', (select count(distinct user_id) from o where dia = hoje and site = 'novo'),
    'ativos_14d', (select count(*) from ult where public._m_dia(opened_at) >= hoje - 13),
    'antigo_14d', (select count(*) from lista where public._m_dia(ult) >= hoje - 13),
    'sem_novo_30d', (select count(*) from pend),
    'sem_aviso', (select count(*) from lista where sem_aviso),
    'pronto', (select count(*) = 0 from pend),
    'banner', (select jsonb_build_object('pessoas', count(distinct user_id), 'vezes', count(*)) from app_events where name = 'dominio_novo_aberto' and user_id <> all(ex)),
    'versoes', coalesce((select jsonb_agg(jsonb_build_object('versao', v, 'pessoas', n) order by n desc)
      from (select coalesce(versao,'antes da v164') v, count(*) n from ult where public._m_dia(opened_at) >= hoje - 13 group by 1) q), '[]'::jsonb),
    'ainda_antigo', coalesce((select jsonb_agg(jsonb_build_object('email', email, 'ultima', ult, 'versao', versao, 'dias', dias, 'sem_aviso', sem_aviso, 'sem_novo', sem_novo) order by ult desc) from lista), '[]'::jsonb)
  ) into r;
  return r;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_m_geral()','admin_m_retencao()','admin_m_funil()','admin_m_funcoes(integer)','admin_m_convites(integer)','admin_m_dominio(integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- A lista de contas excluídas não deve ser chamada de fora; só as funções admin_m_* (security definer) a usam.
revoke all on function public._m_excl() from public, anon, authenticated;
