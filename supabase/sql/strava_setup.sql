create table public.strava_connections (
  user_id uuid primary key references auth.users(id) on delete cascade,
  athlete_id bigint,
  access_token text not null,
  refresh_token text not null,
  expires_at bigint not null,
  last_sync_at timestamptz,
  synced_activity_ids jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.strava_connections enable row level security;

create policy strava_select_own on public.strava_connections
  for select using (auth.uid() = user_id);

create policy strava_insert_own on public.strava_connections
  for insert with check (auth.uid() = user_id);

create policy strava_update_own on public.strava_connections
  for update using (auth.uid() = user_id);

create policy strava_delete_own on public.strava_connections
  for delete using (auth.uid() = user_id);
