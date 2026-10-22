-- Fase 5: Meus ritmos de corrida, turmas do treinador, desafio de distância. Seguro rodar de novo.
-- Requer base_app_e_amigos.sql (app_data), coach_setup.sql (coach_links), challenge_timeline.sql e challenge_acertos.sql.

-- 1. Meus ritmos: teste do aluno (3 km, 5 km ou Cooper) sincronizado com a nuvem.
alter table public.app_data add column if not exists ritmos jsonb;

-- O treinador lê os ritmos do aluno (vínculo ativo + permissão ver_corrida) para sugerir paces.
create or replace function public.coach_aluno_ritmos(p_link uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_aluno uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select l.student_id into v_aluno from public.coach_links l
    where l.id = p_link and l.coach_id = auth.uid() and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_corrida')::boolean, true);
  if v_aluno is null then return null; end if;
  return (select d.ritmos from public.app_data d where d.user_id = v_aluno);
end;
$$;
revoke execute on function public.coach_aluno_ritmos(uuid) from public, anon;
grant execute on function public.coach_aluno_ritmos(uuid) to authenticated;

-- 2. Turmas: grupos de vínculos do treinador para montar uma semana e enviar para todos.
create table if not exists public.coach_turmas (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  links uuid[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists coach_turmas_coach_idx on public.coach_turmas (coach_id);
alter table public.coach_turmas enable row level security;
drop policy if exists coach_turmas_own on public.coach_turmas;
create policy coach_turmas_own on public.coach_turmas for all to authenticated
  using (coach_id = auth.uid()) with check (coach_id = auth.uid() and cardinality(links) <= 200);

-- 3. Desafio de distância: cada check-in de corrida guarda os km; modo "km" nas regras soma a distância.
alter table public.challenge_checkins add column if not exists km numeric(6,1) check (km is null or (km >= 0 and km <= 999));

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
      select jsonb_agg(jsonb_build_object('user_id', k.user_id, 'date', k.date, 'tipo', k.tipo, 'label', k.label, 'minutos', k.minutos, 'km', k.km, 'source', k.source, 'created_at', k.created_at))
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


create or replace function public._challenge_pts(p_id uuid)
returns table (week_idx int, user_id uuid, cnt int, pts int)
language plpgsql security definer set search_path = public as $$
declare
  ch public.challenges;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r jsonb;
  dias int[];
  pontos int[];
  bj int;
  maxdia int;
begin
  select * into ch from public.challenges where id = p_id;
  if not found then return; end if;
  r := coalesce(ch.rules, '{}'::jsonb);
  select coalesce(array_agg(x::int), '{}') into dias from jsonb_array_elements_text(coalesce(r->'dias', '[]'::jsonb)) x;
  if coalesce(array_length(dias, 1), 0) in (0, 7) then dias := array[0,1,2,3,4,5,6]; end if;
  select coalesce(array_agg(x::int order by ord), array[0]) into pontos
    from jsonb_array_elements_text(coalesce(r->'pontos', '[0]'::jsonb)) with ordinality t(x, ord);
  bj := coalesce(nullif(r->>'bonusJuntos', '')::int, 0);
  maxdia := coalesce(nullif(r->>'maxPorDia', '')::int, 0);

  -- Desafio de distância (fase 5): pontos = décimos de km das corridas da semana (só a ordem importa no acerto).
  if r->>'modo' = 'km' then
    return query
    with wk as (
      select g as idx, ch.start_date + g * 7 as ws, ch.start_date + g * 7 + 6 as we
      from generate_series(0, ch.weeks - 1) g
      where ch.start_date + g * 7 + 7 < hoje
    ),
    mem as (
      select m.user_id as uid, (m.joined_at at time zone 'America/Sao_Paulo')::date as jd from public.challenge_members m where m.challenge_id = p_id
    ),
    elig as (
      select wk.idx, wk.ws, wk.we, mem.uid from wk join mem on (mem.jd <= wk.ws or mem.uid = ch.owner_id)
    ),
    soma as (
      select e.idx, e.uid, count(k.*)::int as n, coalesce(sum(k.km), 0) as km
      from elig e join public.challenge_checkins k
        on k.challenge_id = p_id and k.user_id = e.uid and k.date between e.ws and e.we and coalesce(k.km, 0) > 0
       and extract(dow from k.date)::int = any (dias)
      group by e.idx, e.uid
    )
    select e.idx, e.uid, coalesce(s.n, 0), round(coalesce(s.km, 0) * 10)::int
    from elig e left join soma s on s.idx = e.idx and s.uid = e.uid;
    return;
  end if;

  return query
  with wk as (
    select g as idx, ch.start_date + g * 7 as ws, ch.start_date + g * 7 + 6 as we
    from generate_series(0, ch.weeks - 1) g
    where ch.start_date + g * 7 + 7 < hoje          -- fecha com 1 dia de folga (sincronizações atrasadas)
  ),
  mem as (
    select m.user_id as uid, (m.joined_at at time zone 'America/Sao_Paulo')::date as jd from public.challenge_members m where m.challenge_id = p_id
  ),
  elig as (
    select wk.idx, wk.ws, wk.we, mem.uid from wk join mem on (mem.jd <= wk.ws or mem.uid = ch.owner_id)
  ),
  porDia as (
    select e.idx, e.uid, k.date, count(distinct k.tipo)::int as c
    from elig e join public.challenge_checkins k
      on k.challenge_id = p_id and k.user_id = e.uid and k.date between e.ws and e.we
     and extract(dow from k.date)::int = any (dias)
    group by e.idx, e.uid, k.date
  ),
  cont as (
    select idx, uid, sum(case when maxdia > 0 then least(maxdia, c) else c end)::int as n from porDia group by idx, uid
  ),
  bon as (
    select e.idx, e.uid, count(*)::int as b
    from elig e join public.challenge_together t
      on t.challenge_id = p_id and t.status = 'confirmed' and t.date between e.ws and e.we
     and (t.from_user = e.uid or t.to_user = e.uid)
     and extract(dow from t.date)::int = any (dias)
     and exists (select 1 from public.challenge_checkins a where a.challenge_id = p_id and a.user_id = t.from_user and a.date = t.date)
     and exists (select 1 from public.challenge_checkins b2 where b2.challenge_id = p_id and b2.user_id = t.to_user and b2.date = t.date)
    group by e.idx, e.uid
  )
  select e.idx, e.uid, coalesce(c.n, 0),
         pontos[least(coalesce(c.n, 0), array_length(pontos, 1) - 1) + 1] + coalesce(b.b, 0) * bj
  from elig e
  left join cont c on c.idx = e.idx and c.uid = e.uid
  left join bon b on b.idx = e.idx and b.uid = e.uid;
end;
$$;

revoke all on function public._challenge_pts(uuid) from public, anon, authenticated;
