-- Eventos de uso do app (só nome + usuário + hora), pra medir adoção de
-- funcionalidades no painel de admin — por enquanto, os ajustes no treino do
-- dia: treino_concluido, treino_concluido_com_ajuste, ficha_salva_com_ajustes.

create table if not exists public.app_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

alter table public.app_events enable row level security;

grant insert on public.app_events to authenticated;

drop policy if exists app_events_insert_own on public.app_events;
create policy app_events_insert_own on public.app_events
  for insert with check (auth.uid() = user_id);

-- Contagem por evento nos últimos N dias (default 30): total de eventos e
-- quantos usuários diferentes. Mesmo esquema de segurança das outras funções
-- admin: security definer + confere o e-mail de quem chamou; pra qualquer
-- outro usuário não devolve nenhuma linha.
drop function if exists public.admin_event_counts(int);

create function public.admin_event_counts(dias int default 30)
returns table (name text, total bigint, usuarios bigint)
language sql
security definer
set search_path = public, auth
as $$
  select e.name, count(*) as total, count(distinct e.user_id) as usuarios
  from public.app_events e
  where e.created_at >= now() - make_interval(days => dias)
    and (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  group by e.name;
$$;

grant execute on function public.admin_event_counts(int) to authenticated;
