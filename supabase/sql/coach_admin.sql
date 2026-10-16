-- Admin: liberar/retirar treinadores pelo painel (Configurações > Uso). Requer coach_setup.sql.
-- Só o e-mail admin consegue usar. Seguro rodar de novo.

drop function if exists public.admin_coach_list();
create function public.admin_coach_list()
returns table (user_id uuid, email text, nome_exibicao text, liberado boolean, alunos int)
language sql security definer set search_path = public, auth as $$
  select p.user_id, u.email::text, p.nome_exibicao, p.liberado,
         (select count(*)::int from public.coach_links l where l.coach_id = p.user_id and l.status in ('ativo','pausado'))
  from public.coach_profiles p
  join auth.users u on u.id = p.user_id
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  order by p.created_at desc;
$$;

create or replace function public.admin_set_coach(p_email text, p_nome text, p_liberado boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if (select email from auth.users where id = auth.uid()) is distinct from 'ardurso@gmail.com' then
    raise exception 'not allowed';
  end if;
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then raise exception 'usuario_nao_encontrado'; end if;
  insert into public.coach_profiles (user_id, nome_exibicao, liberado)
  values (v_id, coalesce(nullif(left(trim(coalesce(p_nome, '')), 60), ''), 'Treinador'), p_liberado)
  on conflict (user_id) do update set
    liberado = p_liberado,
    nome_exibicao = case when nullif(trim(coalesce(p_nome, '')), '') is not null then left(trim(p_nome), 60) else public.coach_profiles.nome_exibicao end;
  return true;
end;
$$;

revoke execute on function public.admin_coach_list() from public, anon;
revoke execute on function public.admin_set_coach(text, text, boolean) from public, anon;
grant execute on function public.admin_coach_list() to authenticated;
grant execute on function public.admin_set_coach(text, text, boolean) to authenticated;
