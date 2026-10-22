-- Fase 5: Meus ritmos de corrida, turmas do treinador. Seguro rodar de novo.
-- Requer base_app_e_amigos.sql (app_data) e coach_setup.sql (coach_links).

-- 1. Meus ritmos: teste do aluno (3 km, 5 km ou Cooper) sincronizado com a nuvem.
alter table public.app_data add column if not exists ritmos jsonb;

-- O treinador lê os ritmos do aluno (vínculo ativo + permissão ver_corrida) para sugerir paces.
create or replace function public.coach_aluno_ritmos(p_link uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_aluno uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select l.student_id into v_aluno from public.coach_links l
    where l.id = p_link and l.coach_id = auth.uid() and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_corrida')::boolean, true);
  if v_aluno is null then return null; end if;
  return (select d.ritmos from public.app_data d where d.user_id = v_aluno);
end;
$$;
revoke execute on function public.coach_aluno_ritmos(uuid) from public, anon;
grant execute on function public.coach_aluno_ritmos(uuid) to authenticated;

-- 2. Turmas: grupos de vínculos do treinador para montar uma semana e enviar para todos.
create table if not exists public.coach_turmas (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  links uuid[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists coach_turmas_coach_idx on public.coach_turmas (coach_id);
alter table public.coach_turmas enable row level security;
drop policy if exists coach_turmas_own on public.coach_turmas;
create policy coach_turmas_own on public.coach_turmas for all to authenticated
  using (coach_id = auth.uid()) with check (coach_id = auth.uid() and cardinality(links) <= 200);
