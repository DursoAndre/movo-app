-- Painel de admin: consumo da geração de plano de corrida com IA.
-- Uma linha por pessoa que gerou planos (mês atual no horário de São Paulo + total desde sempre).
-- Só o admin recebe linhas. Seguro rodar de novo. Requer plan_generations_setup.sql.

drop function if exists public.admin_plan_usage();

create function public.admin_plan_usage()
returns table (email text, no_mes bigint, total bigint, ultima timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select u.email::text,
         count(*) filter (where g.created_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') as no_mes,
         count(*) as total,
         max(g.created_at) as ultima
  from public.plan_generations g
  join auth.users u on u.id = g.user_id
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  group by u.email
  order by no_mes desc, max(g.created_at) desc
  limit 50;
$$;

revoke all on function public.admin_plan_usage() from public, anon;
grant execute on function public.admin_plan_usage() to authenticated;
