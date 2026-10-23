-- Selfie do "tá pago" no fim do treino (v225). Seguro rodar de novo.
-- Requer challenges_setup.sql (is_challenge_member, challenge_members) e midia_config.sql (midia_ligada).
-- A selfie fica salva no treino (sempre visível para a dona) e, se ela deixar ligado, aparece na linha do
-- tempo dos desafios para quem participa de um desafio com ela. Guardada enquanto a conta existir
-- (decisão do Andre, 23/10). Envio novo só com a chave midia_foto_checkin ligada no painel.
-- Arquivos no bucket privado "selfies": <uid>/<data>-<id>.jpg (1080 px) e <uid>/<data>-<id>-t.jpg (miniatura).

create table if not exists public.treino_selfies (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,
  item_key text not null check (char_length(item_key) <= 120),
  path text not null check (char_length(path) <= 200),
  thumb text not null check (char_length(thumb) <= 200),
  mural boolean not null default true,
  created_at timestamptz not null default now(),
  unique (user_id, date, item_key)
);
create index if not exists treino_selfies_date_idx on public.treino_selfies (date);
alter table public.treino_selfies enable row level security;

-- Divide algum desafio com a pessoa logada? (security definer evita recursão nas políticas)
create or replace function public.selfie_divide_desafio(p_dona uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.challenge_members a
    join public.challenge_members b on b.challenge_id = a.challenge_id
    where a.user_id = auth.uid() and b.user_id = p_dona);
$$;
revoke all on function public.selfie_divide_desafio(uuid) from public, anon;
grant execute on function public.selfie_divide_desafio(uuid) to authenticated;

drop policy if exists treino_selfies_select on public.treino_selfies;
create policy treino_selfies_select on public.treino_selfies for select to authenticated
  using (user_id = auth.uid() or (mural and public.selfie_divide_desafio(user_id)));
drop policy if exists treino_selfies_insert on public.treino_selfies;
create policy treino_selfies_insert on public.treino_selfies for insert to authenticated
  with check (user_id = auth.uid() and public.midia_ligada('foto_checkin')
    and split_part(path, '/', 1) = auth.uid()::text and split_part(thumb, '/', 1) = auth.uid()::text);
drop policy if exists treino_selfies_update on public.treino_selfies;
create policy treino_selfies_update on public.treino_selfies for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid()
    and split_part(path, '/', 1) = auth.uid()::text and split_part(thumb, '/', 1) = auth.uid()::text);
drop policy if exists treino_selfies_delete on public.treino_selfies;
create policy treino_selfies_delete on public.treino_selfies for delete to authenticated
  using (user_id = auth.uid());

-- Arquivo visível para quem pode ver a linha correspondente.
create or replace function public.selfie_arquivo_visivel(p_nome text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.treino_selfies s
    where (s.path = p_nome or s.thumb = p_nome)
      and (s.user_id = auth.uid() or (s.mural and public.selfie_divide_desafio(s.user_id))));
$$;
revoke all on function public.selfie_arquivo_visivel(text) from public, anon;
grant execute on function public.selfie_arquivo_visivel(text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('selfies', 'selfies', false, 716800, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 716800, allowed_mime_types = array['image/jpeg'];

drop policy if exists selfies_insert_own on storage.objects;
create policy selfies_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'selfies' and (storage.foldername(name))[1] = auth.uid()::text and public.midia_ligada('foto_checkin'));
drop policy if exists selfies_select on storage.objects;
create policy selfies_select on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and ((storage.foldername(name))[1] = auth.uid()::text or public.selfie_arquivo_visivel(name)));
drop policy if exists selfies_delete_own on storage.objects;
create policy selfies_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'selfies' and (storage.foldername(name))[1] = auth.uid()::text);
