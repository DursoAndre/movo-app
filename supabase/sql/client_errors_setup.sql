create table public.client_errors (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  context text not null,
  message text,
  created_at timestamptz not null default now()
);

alter table public.client_errors enable row level security;

grant select, insert on public.client_errors to authenticated;

create policy client_errors_insert_own on public.client_errors
  for insert with check (auth.uid() = user_id or user_id is null);
