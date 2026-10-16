-- Painel de admin: moderar provas cadastradas pela comunidade (shared_races).
-- Lista as provas (mais recentes primeiro) com quem cadastrou, e permite esconder/mostrar.
-- Só o admin recebe linhas / consegue alterar. Seguro rodar de novo. Requer races_cloud_setup.sql.

drop function if exists public.admin_shared_races();

create function public.admin_shared_races()
returns table (id bigint, nome text, data_inicio date, cidade text, uf text, modalidade text, oculta boolean, criada_por_email text, created_at timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select r.id, r.nome, r.data_inicio, r.cidade, r.uf, r.modalidade, r.oculta, u.email::text, r.created_at
  from public.shared_races r
  left join auth.users u on u.id = r.criada_por
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  order by r.created_at desc
  limit 100;
$$;

create or replace function public.admin_set_race_oculta(p_id bigint, p_oculta boolean)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if (select email from auth.users where id = auth.uid()) is distinct from 'ardurso@gmail.com' then
    raise exception 'not allowed';
  end if;
  update public.shared_races set oculta = p_oculta where id = p_id;
  return found;
end;
$$;

revoke all on function public.admin_shared_races() from public, anon;
revoke all on function public.admin_set_race_oculta(bigint, boolean) from public, anon;
grant execute on function public.admin_shared_races() to authenticated;
grant execute on function public.admin_set_race_oculta(bigint, boolean) to authenticated;
