-- Convidar amigos da lista direto para um desafio (sem link). O convidado vê um cartão em Desafios e decide.
-- Só amigos (friendships) podem ser convidados. Quem recusou não é convidado de novo automaticamente.

create table if not exists public.challenge_invites (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  from_user uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  primary key (challenge_id, to_user)
);
alter table public.challenge_invites enable row level security;
revoke all on public.challenge_invites from public, anon, authenticated;

create or replace function public.invite_friends_to_challenge(p_id uuid, p_user_ids uuid[])
returns int
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n int := 0;
  k int;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if not public.is_challenge_member(p_id) then raise exception 'você não participa deste desafio'; end if;
  insert into public.challenge_invites (challenge_id, to_user, from_user)
  select p_id, t, me
  from unnest(coalesce(p_user_ids, '{}'::uuid[])) t
  where t <> me
    and exists (select 1 from public.friendships f where f.user_a = least(me, t) and f.user_b = greatest(me, t))
    and not exists (select 1 from public.challenge_members m where m.challenge_id = p_id and m.user_id = t)
  on conflict do nothing;
  get diagnostics k = row_count;
  return k;
end;
$$;

-- Quem já foi convidado (para a lista mostrar "convidado").
create or replace function public.challenge_invited_ids(p_id uuid)
returns uuid[]
language sql security definer stable set search_path = public as $$
  select coalesce(array_agg(to_user), '{}'::uuid[])
  from public.challenge_invites
  where challenge_id = p_id and status = 'pending' and public.is_challenge_member(p_id);
$$;

-- Convites que eu recebi (pendentes).
create or replace function public.my_challenge_invites()
returns jsonb
language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'challenge_id', c.id, 'nome', c.nome, 'start_date', c.start_date, 'weeks', c.weeks, 'stakes', c.stakes,
    'members', (select count(*) from public.challenge_members m where m.challenge_id = c.id),
    'from_nome', coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)),
    'created_at', i.created_at
  ) order by i.created_at desc), '[]'::jsonb)
  from public.challenge_invites i
  join public.challenges c on c.id = i.challenge_id
  join auth.users u on u.id = i.from_user
  left join public.app_data a on a.user_id = i.from_user
  where i.to_user = auth.uid() and i.status = 'pending';
$$;

create or replace function public.accept_challenge_invite(p_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.challenge_invites where challenge_id = p_id and to_user = auth.uid() and status = 'pending') then
    raise exception 'convite não encontrado';
  end if;
  insert into public.challenge_members (challenge_id, user_id) values (p_id, auth.uid()) on conflict do nothing;
  update public.challenge_invites set status = 'accepted' where challenge_id = p_id and to_user = auth.uid();
  return p_id;
end;
$$;

create or replace function public.decline_challenge_invite(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.challenge_invites set status = 'declined' where challenge_id = p_id and to_user = auth.uid() and status = 'pending';
end;
$$;

revoke all on function public.invite_friends_to_challenge(uuid, uuid[]) from public, anon;
revoke all on function public.challenge_invited_ids(uuid) from public, anon;
revoke all on function public.my_challenge_invites() from public, anon;
revoke all on function public.accept_challenge_invite(uuid) from public, anon;
revoke all on function public.decline_challenge_invite(uuid) from public, anon;
grant execute on function public.invite_friends_to_challenge(uuid, uuid[]) to authenticated;
grant execute on function public.challenge_invited_ids(uuid) to authenticated;
grant execute on function public.my_challenge_invites() to authenticated;
grant execute on function public.accept_challenge_invite(uuid) to authenticated;
grant execute on function public.decline_challenge_invite(uuid) to authenticated;
