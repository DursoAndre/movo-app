-- Grava só os dias de sessão alterados (mescla por dia), sem sobrescrever os outros dias da nuvem.
-- Roda com os direitos de quem chama (RLS vale): cada pessoa só mexe na própria linha.
create or replace function public.save_sessions_days(p_days jsonb)
returns void
language sql
security invoker
set search_path = public
as $$
  insert into public.app_data (user_id, sessions, updated_at)
  values (auth.uid(), p_days, now())
  on conflict (user_id) do update
    set sessions = public.app_data.sessions || excluded.sessions,
        updated_at = now();
$$;

revoke execute on function public.save_sessions_days(jsonb) from public, anon;
grant execute on function public.save_sessions_days(jsonb) to authenticated;
