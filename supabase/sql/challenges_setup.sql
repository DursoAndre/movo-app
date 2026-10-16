-- Desafios entre amigos (estilo "gymrats"): grupo com regras, semanas, pontos e aposta.
-- Rodar uma vez no SQL Editor do Supabase. É seguro rodar de novo (idempotente).
--
-- Modelo:
--   challenges          o desafio (nome, início, nº de semanas, regras em JSON, apostas, código de convite)
--   challenge_members   quem participa
--   challenge_checkins  1 linha por (pessoa, dia, tipo de atividade) — é o que conta pro placar
--   challenge_together  "treinei com fulano" (só vale o bônus quando o outro confirma)
-- Os pontos são calculados no app a partir dos check-ins (regra transparente e fácil de mudar).
-- Só participantes enxergam o desafio. Cargas, notas e fichas NÃO são compartilhadas: só dia, tipo e minutos.

create table if not exists public.challenges (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  nome text not null,
  start_date date not null,
  weeks int not null check (weeks between 1 and 26),
  week_start int not null default 1 check (week_start between 0 and 6),
  rules jsonb not null,
  stakes jsonb not null default '{}'::jsonb,
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.challenge_members (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (challenge_id, user_id)
);

create table if not exists public.challenge_checkins (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  tipo text not null,
  label text,
  minutos int,
  source text not null default 'app',
  created_at timestamptz not null default now(),
  primary key (challenge_id, user_id, date, tipo)
);

create table if not exists public.challenge_together (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  date date not null,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'declined')),
  created_at timestamptz not null default now(),
  primary key (challenge_id, date, from_user, to_user),
  check (from_user <> to_user)
);

create index if not exists challenge_members_user_idx on public.challenge_members (user_id);
create index if not exists challenge_checkins_challenge_idx on public.challenge_checkins (challenge_id, date);

-- Helper: a pessoa logada participa deste desafio? (security definer evita recursão nas políticas)
create or replace function public.is_challenge_member(p_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.challenge_members
    where challenge_id = p_id and user_id = auth.uid()
  );
$$;

alter table public.challenges enable row level security;
alter table public.challenge_members enable row level security;
alter table public.challenge_checkins enable row level security;
alter table public.challenge_together enable row level security;

-- challenges / challenge_members: leitura só de quem participa. Escrita só pelas funções abaixo.
drop policy if exists challenges_select on public.challenges;
create policy challenges_select on public.challenges
  for select to authenticated using (public.is_challenge_member(id));

drop policy if exists challenge_members_select on public.challenge_members;
create policy challenge_members_select on public.challenge_members
  for select to authenticated using (public.is_challenge_member(challenge_id));

-- check-ins: todo mundo do grupo vê; cada pessoa só escreve os próprios.
drop policy if exists challenge_checkins_select on public.challenge_checkins;
create policy challenge_checkins_select on public.challenge_checkins
  for select to authenticated using (public.is_challenge_member(challenge_id));

drop policy if exists challenge_checkins_insert on public.challenge_checkins;
create policy challenge_checkins_insert on public.challenge_checkins
  for insert to authenticated
  with check (user_id = auth.uid() and public.is_challenge_member(challenge_id));

drop policy if exists challenge_checkins_update on public.challenge_checkins;
create policy challenge_checkins_update on public.challenge_checkins
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists challenge_checkins_delete on public.challenge_checkins;
create policy challenge_checkins_delete on public.challenge_checkins
  for delete to authenticated using (user_id = auth.uid());

-- treinei com: quem pede cria; quem foi citado confirma/recusa; quem pediu pode apagar.
drop policy if exists challenge_together_select on public.challenge_together;
create policy challenge_together_select on public.challenge_together
  for select to authenticated using (public.is_challenge_member(challenge_id));

drop policy if exists challenge_together_insert on public.challenge_together;
create policy challenge_together_insert on public.challenge_together
  for insert to authenticated
  with check (
    from_user = auth.uid()
    and status = 'pending'
    and public.is_challenge_member(challenge_id)
    and exists (select 1 from public.challenge_members m where m.challenge_id = challenge_together.challenge_id and m.user_id = challenge_together.to_user)
  );

drop policy if exists challenge_together_update on public.challenge_together;
create policy challenge_together_update on public.challenge_together
  for update to authenticated
  using (to_user = auth.uid()) with check (to_user = auth.uid());

drop policy if exists challenge_together_delete on public.challenge_together;
create policy challenge_together_delete on public.challenge_together
  for delete to authenticated using (from_user = auth.uid());

-- ---------------------------------------------------------------------------
-- Funções (RPC)
-- ---------------------------------------------------------------------------

create or replace function public.create_challenge(
  p_nome text, p_start date, p_weeks int, p_week_start int, p_rules jsonb, p_stakes jsonb
)
returns public.challenges
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_row public.challenges;
  v_try int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome obrigatório'; end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.challenges where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código de convite'; end if;
  end loop;
  insert into public.challenges (owner_id, nome, start_date, weeks, week_start, rules, stakes, invite_code)
  values (auth.uid(), trim(p_nome), p_start, p_weeks, p_week_start, p_rules, coalesce(p_stakes, '{}'::jsonb), v_code)
  returning * into v_row;
  insert into public.challenge_members (challenge_id, user_id) values (v_row.id, auth.uid());
  return v_row;
end;
$$;

-- Pré-visualização do convite (antes de entrar): nome, datas, nº de pessoas.
create or replace function public.challenge_preview(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.challenges;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v from public.challenges where invite_code = upper(trim(p_code));
  if not found then return null; end if;
  return jsonb_build_object(
    'id', v.id,
    'nome', v.nome,
    'start_date', v.start_date,
    'weeks', v.weeks,
    'members', (select count(*) from public.challenge_members where challenge_id = v.id),
    'already_member', exists (select 1 from public.challenge_members where challenge_id = v.id and user_id = auth.uid())
  );
end;
$$;

create or replace function public.join_challenge(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select id into v_id from public.challenges where invite_code = upper(trim(p_code));
  if v_id is null then raise exception 'convite inválido'; end if;
  insert into public.challenge_members (challenge_id, user_id) values (v_id, auth.uid())
  on conflict do nothing;
  return v_id;
end;
$$;

create or replace function public.leave_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.challenges where id = p_id;
  if v_owner is null then return; end if;
  if v_owner = auth.uid() then raise exception 'quem criou não pode sair: exclua o desafio'; end if;
  delete from public.challenge_checkins where challenge_id = p_id and user_id = auth.uid();
  delete from public.challenge_together where challenge_id = p_id and (from_user = auth.uid() or to_user = auth.uid());
  delete from public.challenge_members where challenge_id = p_id and user_id = auth.uid();
end;
$$;

create or replace function public.delete_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.challenges where id = p_id and owner_id = auth.uid();
end;
$$;

-- Só quem criou edita. Nome e apostas a qualquer momento; as regras só até o dia do início
-- (depois travam, pra ninguém mudar o jogo no meio).
create or replace function public.update_challenge(p_id uuid, p_nome text, p_rules jsonb, p_stakes jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.challenges;
begin
  select * into v from public.challenges where id = p_id and owner_id = auth.uid();
  if not found then raise exception 'só quem criou o desafio pode editar'; end if;
  if p_rules is distinct from v.rules and current_date >= v.start_date then
    raise exception 'as regras ficam travadas depois que o desafio começa';
  end if;
  update public.challenges
     set nome = coalesce(nullif(trim(p_nome), ''), nome),
         rules = coalesce(p_rules, rules),
         stakes = coalesce(p_stakes, stakes)
   where id = p_id;
end;
$$;

create or replace function public.my_challenges()
returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(jsonb_agg(
    to_jsonb(c) || jsonb_build_object('members', (select count(*) from public.challenge_members m2 where m2.challenge_id = c.id))
    order by c.start_date desc
  ), '[]'::jsonb)
  from public.challenges c
  join public.challenge_members m on m.challenge_id = c.id
  where m.user_id = auth.uid();
$$;

-- Tudo que a tela do desafio precisa, numa chamada só (só pra quem participa).
create or replace function public.challenge_overview(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.is_challenge_member(p_id) then raise exception 'você não participa deste desafio'; end if;
  select jsonb_build_object(
    'challenge', (select to_jsonb(c) from public.challenges c where c.id = p_id),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id,
        'nome', coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)),
        'is_me', m.user_id = auth.uid()
      ) order by m.joined_at)
      from public.challenge_members m
      join auth.users u on u.id = m.user_id
      left join public.app_data a on a.user_id = m.user_id
      where m.challenge_id = p_id
    ), '[]'::jsonb),
    'checkins', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', k.user_id, 'date', k.date, 'tipo', k.tipo, 'label', k.label, 'minutos', k.minutos, 'source', k.source))
      from public.challenge_checkins k where k.challenge_id = p_id
    ), '[]'::jsonb),
    'together', coalesce((
      select jsonb_agg(jsonb_build_object('date', t.date, 'from_user', t.from_user, 'to_user', t.to_user, 'status', t.status))
      from public.challenge_together t where t.challenge_id = p_id
    ), '[]'::jsonb)
  ) into v;
  return v;
end;
$$;

-- Só usuários logados chamam as funções.
revoke all on function public.is_challenge_member(uuid) from public, anon;
revoke all on function public.create_challenge(text, date, int, int, jsonb, jsonb) from public, anon;
revoke all on function public.challenge_preview(text) from public, anon;
revoke all on function public.join_challenge(text) from public, anon;
revoke all on function public.leave_challenge(uuid) from public, anon;
revoke all on function public.delete_challenge(uuid) from public, anon;
revoke all on function public.update_challenge(uuid, text, jsonb, jsonb) from public, anon;
revoke all on function public.my_challenges() from public, anon;
revoke all on function public.challenge_overview(uuid) from public, anon;

grant execute on function public.is_challenge_member(uuid) to authenticated;
grant execute on function public.create_challenge(text, date, int, int, jsonb, jsonb) to authenticated;
grant execute on function public.challenge_preview(text) to authenticated;
grant execute on function public.join_challenge(text) to authenticated;
grant execute on function public.leave_challenge(uuid) to authenticated;
grant execute on function public.delete_challenge(uuid) to authenticated;
grant execute on function public.update_challenge(uuid, text, jsonb, jsonb) to authenticated;
grant execute on function public.my_challenges() to authenticated;
grant execute on function public.challenge_overview(uuid) to authenticated;

grant select on public.challenges to authenticated;
grant select on public.challenge_members to authenticated;
grant select, insert, update, delete on public.challenge_checkins to authenticated;
grant select, insert, update, delete on public.challenge_together to authenticated;
