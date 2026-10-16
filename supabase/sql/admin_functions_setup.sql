-- Funções de admin: rodam com privilégio elevado (security definer), mas só
-- devolvem dados de verdade se quem chamou for o e-mail admin — pra
-- qualquer outro usuário, o "where" abaixo dá falso pra toda linha e volta
-- vazio. Não é só esconder botão no app: é checado aqui dentro do banco.

-- "ultimo_login" (auth.users.last_sign_in_at) só muda quando a sessão expira
-- e a pessoa precisa logar de novo — pode ficar parado por semanas mesmo com
-- uso diário. "ultimo_acesso"/"acessos_*" vêm de app_opens (1 registro por
-- abertura do app, ver app.js) e são a fonte de verdade de uso real. Mudar
-- as colunas do retorno exige dropar a função antes (create or replace não
-- permite alterar a assinatura de saída).
drop function if exists public.admin_usage_stats();

create function public.admin_usage_stats()
returns table (
  user_id uuid,
  email text,
  cadastrou_em timestamptz,
  ultimo_login timestamptz,
  ultimo_acesso timestamptz,
  ultima_atualizacao timestamptz,
  fez_onboarding boolean,
  conectou_strava boolean,
  acessos_7d bigint,
  acessos_30d bigint,
  dias_com_acesso_7d bigint,
  dias_ativos_7d bigint,
  dias_ativos_30d bigint
)
language sql
security definer
set search_path = public, auth
as $$
  select
    u.id,
    u.email,
    u.created_at,
    u.last_sign_in_at,
    ao.ultimo_acesso,
    ad.updated_at,
    (ad.treinos is not null and jsonb_array_length(ad.treinos) > 0),
    (sc.user_id is not null),
    coalesce(ao.acessos_7d, 0),
    coalesce(ao.acessos_30d, 0),
    coalesce(ao.dias_com_acesso_7d, 0),
    (select count(*) from jsonb_object_keys(coalesce(ad.sessions, '{}'::jsonb)) d
       where d::date >= current_date - interval '7 days'),
    (select count(*) from jsonb_object_keys(coalesce(ad.sessions, '{}'::jsonb)) d
       where d::date >= current_date - interval '30 days')
  from auth.users u
  left join public.app_data ad on ad.user_id = u.id
  left join public.strava_connections sc on sc.user_id = u.id
  left join lateral (
    select
      max(o.opened_at) as ultimo_acesso,
      count(*) filter (where o.opened_at >= now() - interval '7 days') as acessos_7d,
      count(*) filter (where o.opened_at >= now() - interval '30 days') as acessos_30d,
      count(distinct o.opened_at::date) filter (where o.opened_at >= now() - interval '7 days') as dias_com_acesso_7d
    from public.app_opens o
    where o.user_id = u.id
  ) ao on true
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  order by u.created_at desc;
$$;

grant execute on function public.admin_usage_stats() to authenticated;

create or replace function public.admin_client_errors(limit_n int default 50)
returns table (
  created_at timestamptz,
  email text,
  context text,
  message text
)
language sql
security definer
set search_path = public, auth
as $$
  select ce.created_at, u.email, ce.context, ce.message
  from public.client_errors ce
  left join auth.users u on u.id = ce.user_id
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  order by ce.created_at desc
  limit limit_n;
$$;

grant execute on function public.admin_client_errors(int) to authenticated;
