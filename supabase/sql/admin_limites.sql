-- Painel › Saúde › "Limites do plano grátis" (pedido do Andre, 22/10/2026): quanto já foi usado de cada limite gratuito
-- que dá para medir pelo banco. O uso do Resend vem da edge function admin-limites (API /usage) e o último deploy vem
-- da API pública do GitHub, direto do painel. Tráfego de saída e chamadas de edge functions só aparecem no painel do Supabase.
-- Seguro rodar de novo. Rodar depois de painel_gestao.sql, recado_email.sql e push_setup.sql.

create or replace function public.admin_limites() returns jsonb
language plpgsql stable security definer set search_path = public, storage as $$
declare
  mes timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
    'arquivos_mb', round(coalesce((select sum((o.metadata->>'size')::bigint) from storage.objects o), 0) / 1048576.0, 1),
    'arquivos_por_pasta', coalesce((select jsonb_object_agg(bucket_id, mb) from (
        select o.bucket_id, round(sum((o.metadata->>'size')::bigint) / 1048576.0, 1) mb
          from storage.objects o group by o.bucket_id) x), '{}'::jsonb),
    'ativos_mes', (select count(distinct user_id) from public.app_opens where opened_at >= mes),
    'strava', (select count(*) from public.strava_connections),
    'strava_limite', 10,
    'push_mes', (select count(*) from public.push_envios where criado_em >= mes),
    'emails_mes_app', (select count(*) from public.aviso_email_log where created_at >= mes)
                    + (select count(*) from public.convite_email_log where created_at >= mes)
                    + (select count(*) from public.recado_emails where enviado_em >= mes),
    'emails_24h_app', (select count(*) from public.aviso_email_log where created_at >= now() - interval '24 hours')
                    + (select count(*) from public.convite_email_log where created_at >= now() - interval '24 hours')
                    + (select count(*) from public.recado_emails where enviado_em >= now() - interval '24 hours'),
    'recados_mes', (select count(*) from public.recado_emails where enviado_em >= mes));
end $$;
revoke all on function public.admin_limites() from public, anon;
grant execute on function public.admin_limites() to authenticated;
