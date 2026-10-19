-- Quem é admin do Movo: lista de contas (por user_id) em movo_admins, em vez do e-mail escrito em cada função.
-- Fica no começo da ordem porque várias funções (inclusive language sql) chamam is_movo_admin()/movo_admin_uid().
-- Trocar o e-mail da conta não tira o acesso (o user_id não muda). Segundo admin: insert into movo_admins.
create table if not exists public.movo_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now());
alter table public.movo_admins enable row level security; -- sem policies: só funções security definer leem
revoke all on public.movo_admins from anon, authenticated;
insert into public.movo_admins(user_id) select id from auth.users where lower(email) = 'ardurso@gmail.com' on conflict do nothing;

create or replace function public.movo_admin_uid(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_uid is not null and exists (select 1 from public.movo_admins a where a.user_id = p_uid)
$$;

create or replace function public.is_movo_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.movo_admin_uid(auth.uid())
$$;
