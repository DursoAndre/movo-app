-- Registro do aceite da Política de Privacidade e dos Termos (versão + data). Seguro rodar de novo.
create table if not exists public.user_consents (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  versao text not null,
  aceito_em timestamptz not null default now(),
  unique (user_id, versao)
);
alter table public.user_consents enable row level security;
revoke all on public.user_consents from anon;
grant select, insert on public.user_consents to authenticated;
drop policy if exists user_consents_select_own on public.user_consents;
create policy user_consents_select_own on public.user_consents for select to authenticated using (auth.uid() = user_id);
drop policy if exists user_consents_insert_own on public.user_consents;
create policy user_consents_insert_own on public.user_consents for insert to authenticated with check (auth.uid() = user_id);
