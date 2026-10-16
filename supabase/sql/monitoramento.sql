-- Monitoramento: resumo de saúde do app (erros, IA, banco) para o painel admin e para o alerta por e-mail.
-- Seguro rodar de novo. Requer client_errors_setup.sql, ai_usage_cost.sql, ai_kill_switch.sql e app_opens_setup.sql.

create or replace function public.saude_resumo()
returns jsonb
language sql
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'erros_30min', (select count(*) from public.client_errors where created_at > now() - interval '30 minutes'),
    'erros_1h', (select count(*) from public.client_errors where created_at > now() - interval '1 hour'),
    'erros_24h', (select count(*) from public.client_errors where created_at > now() - interval '24 hours'),
    'erros_24h_antes', (select count(*) from public.client_errors where created_at <= now() - interval '24 hours' and created_at > now() - interval '48 hours'),
    'erros_top', coalesce((select jsonb_agg(t) from (
        select context, count(*) as n, max(left(message, 140)) as exemplo
          from public.client_errors where created_at > now() - interval '24 hours'
         group by context order by count(*) desc limit 5) t), '[]'::jsonb),
    'ia_falhas_1h', (select count(*) from public.ai_usage_log where created_at > now() - interval '1 hour' and not ok),
    'ia_total_1h', (select count(*) from public.ai_usage_log where created_at > now() - interval '1 hour'),
    'ia_falhas_24h', (select count(*) from public.ai_usage_log where created_at > now() - interval '24 hours' and not ok),
    'ia_total_24h', (select count(*) from public.ai_usage_log where created_at > now() - interval '24 hours'),
    'ia_hoje_usd', coalesce((select sum(custo_usd) from public.ai_usage_log
        where created_at >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'), 0),
    'ia_teto_usd', coalesce((select (valor)::text::numeric from public.app_config where chave = 'ai_teto_diario_usd'), 5),
    'ia_ativa', coalesce((select (valor)::text::boolean from public.app_config where chave = 'ai_ativa'), true),
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
    'ativos_24h', (select count(distinct user_id) from public.app_opens where opened_at > now() - interval '24 hours')
  );
$$;
revoke all on function public.saude_resumo() from public, anon, authenticated;
grant execute on function public.saude_resumo() to service_role;

create or replace function public.admin_saude()
returns jsonb
language sql
security definer
set search_path = public, auth
as $$
  select public.saude_resumo()
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com';
$$;
revoke all on function public.admin_saude() from public, anon;
grant execute on function public.admin_saude() to authenticated;

-- Agendamento: a cada 15 minutos o banco chama a função alerta-saude (que confere erros/IA/banco e manda e-mail).
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'alerta_cron_secret') then
    perform vault.create_secret(encode(gen_random_bytes(24), 'hex'), 'alerta_cron_secret');
  end if;
end $$;

create or replace function public.alerta_segredo_ok(p text)
returns boolean
language sql
security definer
set search_path = public, vault
as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'alerta_cron_secret' and decrypted_secret = p);
$$;
revoke all on function public.alerta_segredo_ok(text) from public, anon, authenticated;
grant execute on function public.alerta_segredo_ok(text) to service_role;

select cron.unschedule('alerta-saude') where exists (select 1 from cron.job where jobname = 'alerta-saude');
select cron.schedule('alerta-saude', '*/15 * * * *', $job$
  select net.http_post(
    url := 'https://wgdhjkebfvcmgokxscvb.supabase.co/functions/v1/alerta-saude',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'alerta_cron_secret')),
    body := '{}'::jsonb
  );
$job$);
