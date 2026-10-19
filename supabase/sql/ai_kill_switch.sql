-- Teto diário de gasto com IA + interruptor geral (admin). Seguro rodar de novo.
-- Requer ai_quota_kinds.sql e ai_usage_cost.sql.

create table if not exists public.app_config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.app_config enable row level security;
-- sem policies: só as funções abaixo (security definer) leem/escrevem.

insert into public.app_config (chave, valor) values
  ('ai_ativa', 'true'::jsonb),
  ('ai_teto_diario_usd', '5'::jsonb)
on conflict (chave) do nothing;

-- Devolve null se a IA pode ser usada agora, ou o motivo: 'desligada' | 'teto_diario'.
create or replace function public.ai_bloqueio()
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  ativa boolean := coalesce((select (valor)::text::boolean from public.app_config where chave = 'ai_ativa'), true);
  teto numeric := coalesce((select (valor)::text::numeric from public.app_config where chave = 'ai_teto_diario_usd'), 5);
  hoje numeric;
begin
  if not ativa then return 'desligada'; end if;
  if teto > 0 then
    select coalesce(sum(custo_usd), 0) into hoje from public.ai_usage_log
     where created_at >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
    if hoje >= teto and not public.is_movo_admin() then
      return 'teto_diario';
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.ai_bloqueio() from public, anon;
grant execute on function public.ai_bloqueio() to authenticated;

-- Reserva de cota: agora recusa quando a IA está bloqueada.
create or replace function public.reserve_ai_generation(p_kind text, p_label text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
  bloqueio text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  bloqueio := public.ai_bloqueio();
  if bloqueio is not null then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', bloqueio, 'usados', 0, 'limite', max_per_month,
      'mensagem', case bloqueio when 'desligada' then 'A IA está temporariamente desligada. Tente mais tarde.' else 'A IA atingiu o limite de uso de hoje. Tente amanhã.' end);
  end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- Painel do admin: estado atual e gasto de hoje.
create or replace function public.admin_ai_controle()
returns jsonb
language sql
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'ativa', coalesce((select (valor)::text::boolean from public.app_config where chave = 'ai_ativa'), true),
    'teto_usd', coalesce((select (valor)::text::numeric from public.app_config where chave = 'ai_teto_diario_usd'), 5),
    'hoje_usd', coalesce((select sum(custo_usd) from public.ai_usage_log
        where created_at >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'), 0)
  )
  where public.is_movo_admin();
$$;

create or replace function public.admin_ai_definir(p_ativa boolean, p_teto numeric)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('ai_ativa', to_jsonb(coalesce(p_ativa, true)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  if p_teto is not null and p_teto >= 0 then
    insert into public.app_config (chave, valor, atualizado_em) values ('ai_teto_diario_usd', to_jsonb(p_teto), now())
      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
end;
$$;

revoke all on function public.admin_ai_controle() from public, anon;
revoke all on function public.admin_ai_definir(boolean, numeric) from public, anon;
grant execute on function public.admin_ai_controle() to authenticated;
grant execute on function public.admin_ai_definir(boolean, numeric) to authenticated;
