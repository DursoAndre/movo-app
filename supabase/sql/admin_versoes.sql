-- Painel admin: quantas pessoas abriram cada versão do app (última abertura de cada pessoa nos últimos N dias).
-- Requer app_opens_setup.sql e a função is_movo_admin() (catalogo_banco.sql). Seguro rodar de novo.

alter table public.app_opens add column if not exists versao text;

create or replace function public.admin_versoes(p_dias integer default 7)
returns table(versao text, pessoas integer, abriu_por_ultimo timestamptz)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return query
  with ult as (
    select distinct on (o.user_id) o.user_id, coalesce(o.versao, 'antes da v164') as v, o.opened_at
    from app_opens o
    where o.opened_at >= now() - make_interval(days => greatest(1, least(p_dias, 90)))
    order by o.user_id, o.opened_at desc)
  select v, count(*)::int, max(opened_at) from ult group by v order by max(opened_at) desc;
end $$;
revoke all on function public.admin_versoes(integer) from public, anon;
grant execute on function public.admin_versoes(integer) to authenticated;
