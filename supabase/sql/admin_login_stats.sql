-- Logins e saídas por usuário nos últimos N dias (default 7), a partir dos
-- eventos login_codigo / login_link / logout de app_events. Serve pra ver
-- quem está precisando logar de novo toda hora (muitos logins, poucas
-- saídas = a sessão caiu sozinha). Mesmo esquema de segurança das outras
-- funções admin: security definer + confere o e-mail de quem chamou.
drop function if exists public.admin_login_stats(int);

create function public.admin_login_stats(dias int default 7)
returns table (email text, logins bigint, logouts bigint, ultimo_login timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select u.email::text,
         count(*) filter (where e.name in ('login_codigo', 'login_link')) as logins,
         count(*) filter (where e.name = 'logout') as logouts,
         max(e.created_at) filter (where e.name in ('login_codigo', 'login_link')) as ultimo_login
  from public.app_events e
  join auth.users u on u.id = e.user_id
  where e.name in ('login_codigo', 'login_link', 'logout')
    and e.created_at >= now() - make_interval(days => dias)
    and (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  group by u.email
  order by logins desc;
$$;

grant execute on function public.admin_login_stats(int) to authenticated;
