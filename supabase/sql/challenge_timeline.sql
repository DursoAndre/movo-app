-- Linha do tempo dos desafios (v165): horário dos check-ins e reação 👏.
-- Seguro rodar mais de uma vez. Rode no SQL editor do Supabase.

-- Reações (👏) em check-ins do desafio. Só participantes veem; escrita só pela função abaixo.
create table if not exists public.challenge_reactions (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  target_user uuid not null references auth.users(id) on delete cascade,
  date date not null,
  tipo text not null,
  created_at timestamptz not null default now(),
  primary key (challenge_id, user_id, target_user, date, tipo),
  check (user_id <> target_user)
);
alter table public.challenge_reactions enable row level security;

drop policy if exists challenge_reactions_select on public.challenge_reactions;
create policy challenge_reactions_select on public.challenge_reactions
  for select to authenticated using (public.is_challenge_member(challenge_id));

-- Liga/desliga o 👏 num check-in de outra pessoa do desafio. Devolve true se ficou ligado.
create or replace function public.toggle_challenge_reaction(p_id uuid, p_target uuid, p_date date, p_tipo text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ligado boolean;
begin
  if not public.is_challenge_member(p_id) then raise exception 'você não participa deste desafio'; end if;
  if p_target = auth.uid() then raise exception 'não dá pra reagir ao próprio treino'; end if;
  if not exists (select 1 from public.challenge_checkins k where k.challenge_id = p_id and k.user_id = p_target and k.date = p_date and k.tipo = p_tipo) then
    raise exception 'check-in não encontrado';
  end if;
  delete from public.challenge_reactions
    where challenge_id = p_id and user_id = auth.uid() and target_user = p_target and date = p_date and tipo = p_tipo;
  if found then
    ligado := false;
  else
    insert into public.challenge_reactions(challenge_id, user_id, target_user, date, tipo) values (p_id, auth.uid(), p_target, p_date, p_tipo);
    ligado := true;
  end if;
  return ligado;
end;
$$;

revoke all on function public.toggle_challenge_reaction(uuid, uuid, date, text) from public, anon;
grant execute on function public.toggle_challenge_reaction(uuid, uuid, date, text) to authenticated;

-- Visão geral do desafio: agora com o horário do check-in (created_at) e as reações.
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
      select jsonb_agg(jsonb_build_object('user_id', k.user_id, 'date', k.date, 'tipo', k.tipo, 'label', k.label, 'minutos', k.minutos, 'source', k.source, 'created_at', k.created_at))
      from public.challenge_checkins k where k.challenge_id = p_id
    ), '[]'::jsonb),
    'together', coalesce((
      select jsonb_agg(jsonb_build_object('date', t.date, 'from_user', t.from_user, 'to_user', t.to_user, 'status', t.status))
      from public.challenge_together t where t.challenge_id = p_id
    ), '[]'::jsonb),
    'reactions', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'target_user', r.target_user, 'date', r.date, 'tipo', r.tipo))
      from public.challenge_reactions r where r.challenge_id = p_id
    ), '[]'::jsonb)
  ) into v;
  return v;
end;
$$;

revoke all on function public.challenge_overview(uuid) from public, anon;
grant execute on function public.challenge_overview(uuid) to authenticated;
