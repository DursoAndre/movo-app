-- Custo da IA: registra tokens e US$ de cada chamada (inclusive as que falham) e mostra o total no painel admin.
-- Seguro rodar de novo. Requer plan_generations_setup.sql (não depende de dados antigos).

create table if not exists public.ai_usage_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  modelo text,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  custo_usd numeric(12,6) not null default 0,
  ok boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists ai_usage_log_created_idx on public.ai_usage_log (created_at desc);
alter table public.ai_usage_log enable row level security;
-- sem policies: ninguém lê/escreve direto; só as funções abaixo.

create or replace function public.log_ai_usage(p_kind text, p_modelo text, p_in int, p_out int, p_custo numeric, p_ok boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into public.ai_usage_log (user_id, kind, modelo, input_tokens, output_tokens, custo_usd, ok)
  values (auth.uid(), left(p_kind, 40), left(p_modelo, 60), greatest(0, coalesce(p_in, 0)), greatest(0, coalesce(p_out, 0)), greatest(0, coalesce(p_custo, 0)), coalesce(p_ok, true));
end;
$$;
revoke all on function public.log_ai_usage(text, text, int, int, numeric, boolean) from public, anon;
grant execute on function public.log_ai_usage(text, text, int, int, numeric, boolean) to authenticated;

drop function if exists public.admin_ai_cost();
create function public.admin_ai_cost()
returns table (total_usd numeric, mes_usd numeric, chamadas bigint, chamadas_mes bigint, falhas bigint, tokens_in bigint, tokens_out bigint, desde timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select coalesce(sum(l.custo_usd), 0),
         coalesce(sum(l.custo_usd) filter (where l.created_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'), 0),
         count(*),
         count(*) filter (where l.created_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'),
         count(*) filter (where not l.ok),
         coalesce(sum(l.input_tokens), 0)::bigint,
         coalesce(sum(l.output_tokens), 0)::bigint,
         min(l.created_at)
  from public.ai_usage_log l
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com';
$$;
revoke all on function public.admin_ai_cost() from public, anon;
grant execute on function public.admin_ai_cost() to authenticated;
