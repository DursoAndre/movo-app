-- Painel de métricas (movoapp.com.br/admin), aba "Relatos" (v201): relatos de problema
-- (user_feedback tipo 'problema', com contexto e revisão do agente; ver user_feedback_relatos.sql)
-- e os erros mais frequentes de client_errors. Só passa quem é admin (is_movo_admin).
-- Decisão do Andre (19/10): relatos ficam só no painel de métricas, não na aba Admin do app.
create or replace function public.admin_m_relatos(p_dias int default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'auth' as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'relatos', coalesce((
      select jsonb_agg(x order by x.lido, x.criado desc) from (
        select f.id, f.created_at as criado, u.email, nullif(trim(a.display_name), '') as nome,
               f.mensagem, f.contato, f.versao, f.origem, f.contexto, f.revisao, f.revisado_em, f.lido
        from public.user_feedback f
        left join auth.users u on u.id = f.user_id
        left join public.app_data a on a.user_id = f.user_id
        where f.tipo = 'problema' and f.created_at >= now() - make_interval(days => greatest(p_dias, 1))
        order by f.created_at desc
        limit 200
      ) x), '[]'::jsonb),
    'erros', coalesce((
      select jsonb_agg(e order by e.n desc) from (
        select ce.context as contexto, count(*) as n, count(distinct ce.user_id) as pessoas,
               max(ce.created_at) as ultimo, (array_agg(left(ce.message, 300) order by ce.created_at desc))[1] as exemplo
        from public.client_errors ce
        where ce.created_at >= now() - make_interval(days => greatest(p_dias, 1))
        group by ce.context
        order by count(*) desc
        limit 30
      ) e), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_m_relatos(int) from public, anon;
grant execute on function public.admin_m_relatos(int) to authenticated;

create or replace function public.admin_m_relato_lido(p_id bigint, p_lido boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  update public.user_feedback set lido = p_lido where id = p_id and tipo = 'problema';
end $$;
revoke all on function public.admin_m_relato_lido(bigint, boolean) from public, anon;
grant execute on function public.admin_m_relato_lido(bigint, boolean) to authenticated;
