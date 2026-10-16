-- Painel geral de uso (admin): números agregados de todos os usuários — não
-- por pessoa (isso já existe em admin_usage_stats) — pra ver de relance
-- quantos usuários existem, quantos estão ativos e a tendência diária.
-- Mesmo esquema de segurança das outras funções admin: security definer +
-- confere o e-mail de quem chamou (ardurso@gmail.com) antes de devolver
-- qualquer linha; pra qualquer outro usuário, o "where" dá falso e some
-- tudo (nessas duas funções, como não tem "from" de verdade, a query
-- simplesmente não devolve nenhuma linha — não dá erro, só fica vazio).

drop function if exists public.admin_overview_stats();

create function public.admin_overview_stats()
returns table (
  total_usuarios bigint,
  ativos_hoje bigint,
  ativos_7d bigint,
  ativos_30d bigint,
  novos_7d bigint,
  novos_30d bigint,
  completaram_onboarding bigint,
  conectaram_strava bigint,
  tamanho_banco_mb numeric
)
language sql
security definer
set search_path = public, auth
as $$
  -- "Hoje" precisa ser calculado no fuso de Brasília, não em UTC (padrão do
  -- banco) — do contrário, à noite (horário de Brasília), o UTC já virou o
  -- dia seguinte e quem acessou mais cedo some da contagem de "hoje".
  -- date_trunc(...) AT TIME ZONE 'America/Sao_Paulo' é o idioma padrão do
  -- Postgres pra achar "meia-noite de hoje, num fuso específico" como um
  -- instante de verdade (timestamptz), comparável com opened_at.
  select
    (select count(*) from auth.users),
    (select count(distinct user_id) from public.app_opens where opened_at >= (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')),
    (select count(distinct user_id) from public.app_opens where opened_at >= now() - interval '7 days'),
    (select count(distinct user_id) from public.app_opens where opened_at >= now() - interval '30 days'),
    (select count(*) from auth.users where created_at >= now() - interval '7 days'),
    (select count(*) from auth.users where created_at >= now() - interval '30 days'),
    (select count(*) from public.app_data where treinos is not null and jsonb_array_length(treinos) > 0),
    (select count(distinct user_id) from public.strava_connections),
    -- Tamanho do banco todo (não só uma tabela) — plano gratuito do Supabase
    -- tem teto de 500 MB; isso é o que mais cedo vira limite, bem antes do
    -- teto de 50 mil usuários ativos/mês.
    (select round(pg_database_size(current_database()) / 1024.0 / 1024.0, 1))
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com';
$$;

grant execute on function public.admin_overview_stats() to authenticated;

-- "Usuários ativos" por dia nos últimos N dias (default 14), pra desenhar o
-- gráfico de tendência — inclui dias com zero acesso (generate_series),
-- senão um dia parado simplesmente some do gráfico em vez de aparecer como
-- uma barra zerada. Mesmo cuidado de fuso horário do admin_overview_stats:
-- "dia" é calculado em America/Sao_Paulo, não em UTC — senão a barra de
-- "hoje" (e o corte entre um dia e outro) fica até 3h deslocada.
drop function if exists public.admin_daily_active(int);

create function public.admin_daily_active(dias int default 14)
returns table (
  dia date,
  usuarios_ativos bigint
)
language sql
security definer
set search_path = public, auth
as $$
  select s.d::date, coalesce(count(distinct o.user_id), 0)
  from generate_series(
    (now() at time zone 'America/Sao_Paulo')::date - (dias - 1),
    (now() at time zone 'America/Sao_Paulo')::date,
    interval '1 day'
  ) as s(d)
  left join public.app_opens o on (o.opened_at at time zone 'America/Sao_Paulo')::date = s.d::date
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  group by s.d
  order by s.d;
$$;

grant execute on function public.admin_daily_active(int) to authenticated;
