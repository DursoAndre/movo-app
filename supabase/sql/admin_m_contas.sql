-- Painel de métricas (movoapp.com.br/admin), aba "Contas": todas as contas, com cadastro e último acesso.
-- Só passa quem é admin (is_movo_admin). Requer admin_metricas_v2.sql (_m_excl, _m_treino) e admin_metricas_v3.sql (user_origem).
create or replace function public.admin_m_contas() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select coalesce(jsonb_agg(x order by x.cadastro desc), '[]'::jsonb) into r
  from (
    select
      u.id as id,
      nullif(trim(a.display_name), '') as nome,
      u.email as email,
      u.created_at as cadastro,
      o.ultimo as ultimo_acesso,
      u.last_sign_in_at as ultimo_login,
      coalesce(o.n30, 0) as aberturas_30d,
      exists (select 1 from public.app_events e where e.user_id = u.id and e.name = any (public._m_treino())) as treinou,
      coalesce(nullif(og.convite, ''), nullif(og.src, '')) as origem,
      (u.id = any (public._m_excl())) as teste
    from auth.users u
    left join public.app_data a on a.user_id = u.id
    left join public.user_origem og on og.user_id = u.id
    left join lateral (
      select max(p.opened_at) as ultimo, count(*) filter (where p.opened_at >= now() - interval '30 days') as n30
      from public.app_opens p where p.user_id = u.id
    ) o on true
  ) x;
  return r;
end $$;
revoke all on function public.admin_m_contas() from public, anon;
grant execute on function public.admin_m_contas() to authenticated;
