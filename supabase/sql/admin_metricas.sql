-- Painel de métricas (movoapp.com.br/admin/): origem do acesso + consultas agregadas, uma por aba.
-- Só o admin (is_movo_admin) executa; cada função devolve poucos números já somados (nada de listas grandes).
-- Requer app_opens_setup.sql, app_events, lp_events e is_movo_admin() (catalogo_banco.sql). Seguro rodar de novo.

alter table public.app_opens add column if not exists host text;        -- endereço de onde o app foi aberto
alter table public.app_opens add column if not exists instalado boolean; -- aberto como app instalado (PWA)

-- Dia no fuso de São Paulo
create or replace function public._m_dia(t timestamptz) returns date
language sql immutable as $$ select (t at time zone 'America/Sao_Paulo')::date $$;

-- Site de origem de cada abertura: pelo host quando existe; antes disso, pela versão (<= v174 = antigo, >= v175 = novo)
create or replace function public._m_site(p_host text, p_versao text) returns text
language sql immutable as $$
  select case
    when p_host is not null then case when p_host like '%github.io' then 'antigo' else 'novo' end
    when p_versao ~ '^v[0-9]+$' and substring(p_versao from 2)::int >= 175 then 'novo'
    else 'antigo' end $$;

-- Aba "Visão geral"
create or replace function public.admin_m_geral() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'contas', (select count(*) from auth.users),
    'novas_7d', (select count(*) from auth.users where public._m_dia(created_at) >= hoje - 6),
    'novas_hoje', (select count(*) from auth.users where public._m_dia(created_at) = hoje),
    'dau', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) = hoje),
    'wau', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - 6),
    'mau', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - 29),
    'abriram_algum_dia', (select count(distinct user_id) from app_opens),
    'com_treino', (select count(distinct user_id) from app_events where name in ('treino_concluido','primeiro_registro','corrida_registrada_manual')),
    'instalado_7d', (select count(distinct user_id) from app_opens where instalado is true and public._m_dia(opened_at) >= hoje - 6),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', g::date::text, 'pessoas', coalesce(x.p,0), 'aberturas', coalesce(x.a,0), 'novas', coalesce(n.c,0)) order by g), '[]'::jsonb)
      from generate_series(hoje - 29, hoje, interval '1 day') gs(g)
      left join (select public._m_dia(opened_at) d, count(distinct user_id) p, count(*) a from app_opens group by 1) x on x.d = g::date
      left join (select public._m_dia(created_at) d, count(*) c from auth.users group by 1) n on n.d = g::date)
  ) into r;
  return r;
end $$;

-- Aba "Retenção": por semana de cadastro, quantos voltaram (D1 = dia seguinte; D7 = entre o dia 7 e 13; D30 = dia 30 em diante)
create or replace function public.admin_m_retencao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with u as (select id, public._m_dia(created_at) sd from auth.users),
  f as (
    select u.id, u.sd,
      date_trunc('week', u.sd)::date semana,
      (hoje >= u.sd + 1) el1, (hoje >= u.sd + 7) el7, (hoje >= u.sd + 30) el30,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) = u.sd + 1) d1,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) between u.sd + 7 and u.sd + 13) d7,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) >= u.sd + 30) d30
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

-- Aba "Funil": quantas pessoas chegaram em cada etapa (eventos só existem desde 05/10/2026)
create or replace function public.admin_m_funil() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_array(
    jsonb_build_object('etapa','Criaram conta','n',(select count(*) from auth.users)),
    jsonb_build_object('etapa','Abriram o app','n',(select count(distinct user_id) from app_opens)),
    jsonb_build_object('etapa','Aceitaram os termos','n',(select count(distinct user_id) from app_events where name='aceite_registrado')),
    jsonb_build_object('etapa','Começaram o onboarding','n',(select count(distinct user_id) from app_events where name='onboarding_iniciado')),
    jsonb_build_object('etapa','Concluíram o onboarding','n',(select count(distinct user_id) from app_events where name='onboarding_concluido')),
    jsonb_build_object('etapa','Registraram o 1º treino','n',(select count(distinct user_id) from app_events where name in ('treino_concluido','primeiro_registro','corrida_registrada_manual'))),
    jsonb_build_object('etapa','Treinaram em 2 dias ou mais','n',(select count(*) from (select user_id from app_events where name='treino_concluido' group by user_id having count(distinct public._m_dia(created_at)) >= 2) q)),
    jsonb_build_object('etapa','Voltaram 7+ dias após o cadastro','n',(select count(distinct u.id) from auth.users u join app_opens o on o.user_id = u.id and public._m_dia(o.opened_at) >= public._m_dia(u.created_at) + 7))
  ) into r;
  return r;
end $$;

-- Aba "Funcionalidades": pessoas e vezes por evento no período, e quantas dessas pessoas foram ativas nos últimos 7 dias
create or replace function public.admin_m_funcoes(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 365)); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'ativos_7d', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - 6),
    'ativos_periodo', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - (d - 1)),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v, 'pessoas_7d', p7, 'ultima', ult::text) order by p desc, v desc)
      from (select name, count(distinct user_id) p, count(*) v,
              count(distinct user_id) filter (where public._m_dia(created_at) >= hoje - 6) p7,
              max(public._m_dia(created_at)) ult
            from app_events where public._m_dia(created_at) >= hoje - (d - 1) group by name) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Aba "Convites e landing"
create or replace function public.admin_m_convites(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare d int := greatest(1, least(p_dias, 365)); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v) order by name)
      from (select name, count(distinct user_id) p, count(*) v from app_events
            where name in ('convite_whatsapp','desafio_criado','desafio_cartao_compartilhado','desafio_entrou','desafio_aplauso')
              and public._m_dia(created_at) >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'landing', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc)
      from (select name, sum(n)::int n from lp_events where day >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'origens', coalesce((select jsonb_agg(jsonb_build_object('src', src, 'n', n) order by n desc)
      from (select coalesce(nullif(src,''),'(direto)') src, sum(n)::int n from lp_events
            where name in ('visita','page_view','view') and day >= public._m_dia(now()) - (d - 1) group by 1 limit 12) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Aba "Domínio e versões": quem ainda acessa o site antigo
create or replace function public.admin_m_dominio(p_dias integer default 14) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 60)); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'host_desde', (select min(opened_at) from app_opens where host is not null),
    'serie', coalesce((select jsonb_agg(jsonb_build_object('dia', dia::text, 'site', site, 'pessoas', p) order by dia, site)
      from (select public._m_dia(opened_at) dia, public._m_site(host, versao) site, count(distinct user_id) p
            from app_opens where public._m_dia(opened_at) >= hoje - (d - 1) group by 1,2) q), '[]'::jsonb),
    'hoje_antigo', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) = hoje and public._m_site(host, versao) = 'antigo'),
    'hoje_novo', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) = hoje and public._m_site(host, versao) = 'novo'),
    'banner', (select jsonb_build_object('pessoas', count(distinct user_id), 'vezes', count(*)) from app_events where name = 'dominio_novo_aberto'),
    'versoes', coalesce((select jsonb_agg(jsonb_build_object('versao', v, 'pessoas', n) order by n desc)
      from (select coalesce(versao,'antes da v164') v, count(*) n from (
              select distinct on (user_id) user_id, versao from app_opens
              where public._m_dia(opened_at) >= hoje - 6 order by user_id, opened_at desc) z group by 1) q), '[]'::jsonb),
    'ainda_antigo', coalesce((select jsonb_agg(jsonb_build_object('email', email, 'ultima', ult, 'versao', versao, 'dias', dias) order by ult desc)
      from (select u.email, x.ult, x.versao, x.dias from (
              select distinct on (user_id) user_id, opened_at ult, versao from app_opens
              where public._m_dia(opened_at) >= hoje - 6 order by user_id, opened_at desc) l
            join auth.users u on u.id = l.user_id
            join lateral (select l.ult, l.versao, (select count(distinct public._m_dia(o.opened_at)) from app_opens o where o.user_id = l.user_id and public._m_dia(o.opened_at) >= hoje - 6) dias) x on true
            where public._m_site((select o2.host from app_opens o2 where o2.user_id = l.user_id order by o2.opened_at desc limit 1), l.versao) = 'antigo') q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_m_geral()','admin_m_retencao()','admin_m_funil()','admin_m_funcoes(integer)','admin_m_convites(integer)','admin_m_dominio(integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
