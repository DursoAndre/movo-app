-- Provas favoritas (⭐): guardadas para decidir depois, separadas de "Vou nessa" (race_entries).
-- Cada pessoa só enxerga e mexe nas próprias linhas. Não aparece para amigos. Seguro rodar de novo.
create table if not exists public.race_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  race_id text not null check (char_length(race_id) between 1 and 200),
  created_at timestamptz not null default now(),
  primary key (user_id, race_id)
);

alter table public.race_favorites enable row level security;
grant select, insert, update, delete on public.race_favorites to authenticated;

drop policy if exists race_favorites_own on public.race_favorites;
create policy race_favorites_own on public.race_favorites for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
