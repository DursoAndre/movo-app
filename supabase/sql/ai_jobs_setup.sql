-- Geração com IA em segundo plano: o app pede, a função grava o resultado aqui e o app consulta.
-- Assim a pessoa pode sair da tela (ou do app) e o plano continua sendo gerado.
-- Seguro rodar de novo. Requer plan_generations_setup.sql.

create table if not exists public.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  label text,
  status text not null default 'rodando' check (status in ('rodando', 'pronto', 'erro')),
  result jsonb,
  reserva_id bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ai_jobs_user_created_idx on public.ai_jobs (user_id, created_at desc);

alter table public.ai_jobs enable row level security;
grant select on public.ai_jobs to authenticated;
drop policy if exists ai_jobs_select_own on public.ai_jobs;
create policy ai_jobs_select_own on public.ai_jobs for select to authenticated using (auth.uid() = user_id);

-- Tarefas que ficaram "rodando" por mais de 6 minutos (função morreu): marca erro e devolve a reserva do limite.
create or replace function public.expire_stale_ai_jobs()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  with ex as (
    update public.ai_jobs
       set status = 'erro', updated_at = now(),
           result = jsonb_build_object('ok', false, 'erro', 'expirou', 'mensagem', 'A geração demorou demais e foi cancelada. Tente de novo (esta tentativa não conta no limite).')
     where user_id = uid and status = 'rodando' and created_at < now() - interval '6 minutes'
     returning reserva_id
  )
  delete from public.plan_generations where user_id = uid and id in (select reserva_id from ex where reserva_id is not null);
end;
$$;
revoke all on function public.expire_stale_ai_jobs() from public, anon;
grant execute on function public.expire_stale_ai_jobs() to authenticated;

-- Cria a tarefa. Só uma por tipo rodando ao mesmo tempo.
create or replace function public.create_ai_job(p_kind text, p_label text, p_reserva bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  existente uuid;
  novo uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  perform public.expire_stale_ai_jobs();
  select id into existente from public.ai_jobs where user_id = uid and kind = p_kind and status = 'rodando' order by created_at desc limit 1;
  if existente is not null then
    return jsonb_build_object('ok', false, 'erro', 'em_andamento', 'id', existente);
  end if;
  insert into public.ai_jobs (user_id, kind, label, reserva_id) values (uid, left(p_kind, 40), left(p_label, 120), p_reserva) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo);
end;
$$;
revoke all on function public.create_ai_job(text, text, bigint) from public, anon;
grant execute on function public.create_ai_job(text, text, bigint) to authenticated;

-- Grava o resultado final da tarefa.
create or replace function public.finish_ai_job(p_id uuid, p_status text, p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.ai_jobs
     set status = case when p_status = 'pronto' then 'pronto' else 'erro' end, result = p_result, updated_at = now()
   where id = p_id and user_id = auth.uid() and status = 'rodando';
end;
$$;
revoke all on function public.finish_ai_job(uuid, text, jsonb) from public, anon;
grant execute on function public.finish_ai_job(uuid, text, jsonb) to authenticated;
