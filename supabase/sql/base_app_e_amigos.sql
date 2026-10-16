-- Base do app: dados de cada pessoa (app_data) e amizades (friendships / friend_requests).
-- Estes objetos foram criados à mão no começo do projeto; este arquivo os registra, a partir do banco em produção
-- (16/10/2026), para que um projeto novo possa ser montado só com os arquivos desta pasta. Seguro rodar de novo.
-- Rodar ANTES de todos os outros (vários arquivos dependem de public.app_data).

create table if not exists public.app_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  treinos jsonb not null default '[]'::jsonb,
  atividades jsonb not null default '[]'::jsonb,
  schedule jsonb not null default '{}'::jsonb,
  sessions jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  display_name text,
  planos jsonb default '[]'::jsonb
);
alter table public.app_data enable row level security;
drop policy if exists "Users can view own data" on public.app_data;
drop policy if exists "Users can insert own data" on public.app_data;
drop policy if exists "Users can update own data" on public.app_data;
create policy "Users can view own data" on public.app_data for select using (auth.uid() = user_id);
create policy "Users can insert own data" on public.app_data for insert with check (auth.uid() = user_id);
create policy "Users can update own data" on public.app_data for update using (auth.uid() = user_id);
grant select, insert, update on public.app_data to authenticated;

-- Amizades: par ordenado (user_a < user_b), uma linha por amizade.
create table if not exists public.friendships (
  id bigint generated always as identity primary key,
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_a, user_b),
  constraint friendships_order check (user_a < user_b)
);
alter table public.friendships enable row level security;
drop policy if exists friendships_select on public.friendships;
drop policy if exists friendships_delete on public.friendships;
create policy friendships_select on public.friendships for select using (auth.uid() = user_a or auth.uid() = user_b);
create policy friendships_delete on public.friendships for delete using (auth.uid() = user_a or auth.uid() = user_b);
grant select, delete on public.friendships to authenticated;

create table if not exists public.friend_requests (
  id bigint generated always as identity primary key,
  from_user_id uuid not null references auth.users(id) on delete cascade,
  from_email text not null,
  to_email text not null,
  status text not null default 'pendente' check (status in ('pendente', 'aceito', 'recusado')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique (from_user_id, to_email)
);
alter table public.friend_requests enable row level security;
drop policy if exists friend_requests_from_all on public.friend_requests;
drop policy if exists friend_requests_to_select on public.friend_requests;
create policy friend_requests_from_all on public.friend_requests for all using (from_user_id = auth.uid()) with check (from_user_id = auth.uid());
create policy friend_requests_to_select on public.friend_requests for select using (to_email = auth.email());
grant select, insert, update, delete on public.friend_requests to authenticated;

create or replace function public.send_friend_request(p_to_email text)
returns void
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  caller_id uuid := auth.uid();
  caller_email text := auth.email();
  target_id uuid;
  norm_email text := lower(trim(p_to_email));
begin
  if caller_id is null or caller_email is null then
    raise exception 'not_authenticated';
  end if;
  if norm_email = lower(caller_email) then
    raise exception 'cannot_add_self';
  end if;

  select id into target_id from auth.users where lower(email) = norm_email;
  if target_id is null then
    raise exception 'user_not_found';
  end if;

  if exists (
    select 1 from public.friendships
    where user_a = least(caller_id, target_id) and user_b = greatest(caller_id, target_id)
  ) then
    raise exception 'already_friends';
  end if;

  insert into public.friend_requests (from_user_id, from_email, to_email, status)
  values (caller_id, caller_email, norm_email, 'pendente')
  on conflict (from_user_id, to_email)
  do update set status = 'pendente', created_at = now(), responded_at = null;
end;
$$;

create or replace function public.respond_friend_request(p_request_id bigint, p_accept boolean)
returns void
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  caller_id uuid := auth.uid();
  caller_email text := auth.email();
  req public.friend_requests%rowtype;
begin
  if caller_id is null then
    raise exception 'not_authenticated';
  end if;

  select * into req from public.friend_requests where id = p_request_id;
  if not found then
    raise exception 'request_not_found';
  end if;
  if caller_email is null or lower(req.to_email) <> lower(caller_email) then
    raise exception 'not_authorized';
  end if;
  if req.status <> 'pendente' then
    raise exception 'already_responded';
  end if;

  update public.friend_requests
    set status = case when p_accept then 'aceito' else 'recusado' end,
        responded_at = now()
    where id = p_request_id;

  if p_accept then
    insert into public.friendships (user_a, user_b)
    values (least(req.from_user_id, caller_id), greatest(req.from_user_id, caller_id))
    on conflict (user_a, user_b) do nothing;
  end if;
end;
$$;

-- Ranking entre amigos (e você): dias ativos, treinos e minutos no período ('semana', 'mes' ou 'ano').
create or replace function public.get_friend_leaderboard(p_period text default 'semana')
returns table(user_id uuid, nome text, email text, is_me boolean, dias_ativos integer, numero_treinos integer, minutos_totais integer)
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  me uuid := auth.uid();
  days_back int;
  start_date date;
  fid uuid;
  v_sessions jsonb;
  v_display_name text;
  v_email text;
  date_key text;
  session_val jsonb;
  log_val jsonb;
  item_key text;
  item_val jsonb;
  ex_key text;
  ex_val jsonb;
  d_ativos int;
  n_treinos int;
  min_totais numeric;
  has_ativo boolean;
  cargas_sum numeric;
begin
  if me is null then
    raise exception 'not_authenticated';
  end if;

  days_back := case p_period when 'semana' then 7 when 'mes' then 30 when 'ano' then 365 else 7 end;
  start_date := current_date - (days_back - 1);

  create temp table if not exists _friend_ids (id uuid) on commit drop;
  delete from _friend_ids where true;
  insert into _friend_ids values (me);
  insert into _friend_ids
    select case when f.user_a = me then f.user_b else f.user_a end
    from public.friendships f
    where f.user_a = me or f.user_b = me;

  for fid in select id from _friend_ids loop
    select ad.sessions, ad.display_name into v_sessions, v_display_name
      from public.app_data ad where ad.user_id = fid;
    select u.email into v_email from auth.users u where u.id = fid;

    d_ativos := 0;
    n_treinos := 0;
    min_totais := 0;

    for date_key, session_val in select * from jsonb_each(coalesce(v_sessions, '{}'::jsonb))
    loop
      if date_key !~ '^\d{4}-\d{2}-\d{2}$' or date_key::date < start_date then
        continue;
      end if;
      has_ativo := false;
      log_val := coalesce(session_val->'log', '{}'::jsonb);

      for item_key, item_val in select * from jsonb_each(log_val)
      loop
        if item_key like 'treino:%' then
          for ex_key, ex_val in select * from jsonb_each(item_val)
          loop
            if (ex_val->>'status') = 'feito' then
              n_treinos := n_treinos + 1;
              has_ativo := true;
            end if;
          end loop;
        else
          if (item_val->>'status') = 'fui' then
            n_treinos := n_treinos + 1;
            has_ativo := true;
          end if;
        end if;
      end loop;

      select coalesce(sum((v->>'duracaoMin')::numeric), 0) into cargas_sum
        from jsonb_each(coalesce(session_val->'cargas', '{}'::jsonb)) as t(k, v);
      if cargas_sum > 0 then
        has_ativo := true;
        min_totais := min_totais + cargas_sum;
      end if;

      if has_ativo then
        d_ativos := d_ativos + 1;
      end if;
    end loop;

    user_id := fid;
    email := v_email;
    nome := coalesce(v_display_name, split_part(v_email, '@', 1));
    is_me := (fid = me);
    dias_ativos := d_ativos;
    numero_treinos := n_treinos;
    minutos_totais := round(min_totais)::int;
    return next;
  end loop;
end;
$$;

revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_friend_request(bigint, boolean) from public, anon;
revoke all on function public.get_friend_leaderboard(text) from public, anon;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(bigint, boolean) to authenticated;
grant execute on function public.get_friend_leaderboard(text) to authenticated;
