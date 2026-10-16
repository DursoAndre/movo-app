-- Controle de uso da geração de plano de corrida com IA (limite por pessoa por mês).
-- Cada geração reservada conta 1; se a chamada à IA falhar, a função devolve (apaga) a reserva.
-- O limite padrão é 3 por mês (mês do horário de São Paulo) e pode ser mudado nos parâmetros.
-- Seguro rodar de novo.

create table if not exists public.plan_generations (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  prova text check (prova is null or char_length(prova) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists plan_generations_user_created_idx on public.plan_generations (user_id, created_at desc);

alter table public.plan_generations enable row level security;
grant select on public.plan_generations to authenticated;

drop policy if exists plan_generations_select_own on public.plan_generations;
create policy plan_generations_select_own on public.plan_generations
  for select to authenticated using (auth.uid() = user_id);

-- Quantos planos a pessoa já gerou neste mês.
create or replace function public.plan_generation_usage(max_per_month int default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select count(*) into usados from public.plan_generations where user_id = uid and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month);
end;
$$;

-- Reserva uma geração (atômico). Devolve ok=false quando o limite do mês já foi usado.
create or replace function public.reserve_plan_generation(p_prova text default null, max_per_month int default 3)
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
begin
  if uid is null then raise exception 'not authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova) values (uid, left(p_prova, 120)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- Devolve a reserva quando a IA falhou (só apaga linha da própria pessoa).
create or replace function public.refund_plan_generation(p_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.plan_generations where id = p_id and user_id = auth.uid();
$$;

revoke all on function public.plan_generation_usage(int) from public, anon;
revoke all on function public.reserve_plan_generation(text, int) from public, anon;
revoke all on function public.refund_plan_generation(bigint) from public, anon;
grant execute on function public.plan_generation_usage(int) to authenticated;
grant execute on function public.reserve_plan_generation(text, int) to authenticated;
grant execute on function public.refund_plan_generation(bigint) to authenticated;
