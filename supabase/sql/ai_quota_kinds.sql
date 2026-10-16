-- Cota mensal de IA por tipo ('plano_corrida', 'historico', ...). Seguro rodar de novo.
-- Requer plan_generations_setup.sql. Substitui as funções de cota (já inclui o "sem limite" do admin).

alter table public.plan_generations add column if not exists kind text not null default 'plano_corrida';

create or replace function public.ai_generation_usage(p_kind text, max_per_month int)
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
  if (select email from auth.users where id = uid) = 'ardurso@gmail.com' then max_per_month := 1000000; end if;
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month);
end;
$$;

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
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if (select email from auth.users where id = uid) = 'ardurso@gmail.com' then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

create or replace function public.plan_generation_usage(max_per_month int default 3)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.ai_generation_usage('plano_corrida', max_per_month);
$$;

create or replace function public.reserve_plan_generation(p_prova text default null, max_per_month int default 3)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.reserve_ai_generation('plano_corrida', p_prova, max_per_month);
$$;

revoke all on function public.ai_generation_usage(text, int) from public, anon;
revoke all on function public.reserve_ai_generation(text, text, int) from public, anon;
grant execute on function public.ai_generation_usage(text, int) to authenticated;
grant execute on function public.reserve_ai_generation(text, text, int) to authenticated;
