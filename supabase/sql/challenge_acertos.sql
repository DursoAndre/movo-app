-- Prêmios P1: controle de acertos dos desafios. O Movo NÃO toca em dinheiro: só organiza a conta.
-- Valores em R$ ficam em challenges.stakes (semana_valor, final_valor, termos) e travam quando o desafio começa.
-- O fechamento das semanas é calculado AQUI (servidor) e gravado num livro-caixa imutável (challenge_ledger).
-- Correção = novo lançamento / "perdoar"; nunca edição. Idempotente.

create table if not exists public.challenge_ledger (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  kind text not null check (kind in ('semana', 'final')),
  week_idx int not null,                       -- 0..n-1 para semana; -1 para final
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  valor_cents int not null check (valor_cents > 0),
  created_at timestamptz not null default now(),
  unique (challenge_id, kind, week_idx, from_user, to_user),
  check (from_user <> to_user)
);
create index if not exists challenge_ledger_ch_idx on public.challenge_ledger (challenge_id);

-- Estado de cada lançamento (só mexe via funções).
create table if not exists public.challenge_acerto_status (
  ledger_id uuid primary key references public.challenge_ledger(id) on delete cascade,
  paid_at timestamptz,
  received_at timestamptz,
  forgiven_at timestamptz,
  contested_at timestamptz,
  contest_note text
);

alter table public.challenge_ledger enable row level security;
alter table public.challenge_acerto_status enable row level security;
revoke all on public.challenge_ledger from public, anon, authenticated;
revoke all on public.challenge_acerto_status from public, anon, authenticated;

-- O livro-caixa nunca é editado.
create or replace function public._ledger_imutavel() returns trigger language plpgsql as $$
begin raise exception 'lançamentos do livro-caixa não podem ser alterados'; end;
$$;
create or replace trigger challenge_ledger_no_update before update on public.challenge_ledger
  for each row execute function public._ledger_imutavel();

-- Valores: limites, 18+ e travados depois do início.
create or replace function public._challenge_stakes_check() returns trigger language plpgsql as $$
declare
  vs numeric := coalesce(nullif(new.stakes->>'semana_valor', '')::numeric, 0);
  vf numeric := coalesce(nullif(new.stakes->>'final_valor', '')::numeric, 0);
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if vs < 0 or vs > 500 then raise exception 'valor da semana deve ficar entre R$ 0 e R$ 500'; end if;
  if vf < 0 or vf > 2000 then raise exception 'valor final deve ficar entre R$ 0 e R$ 2000'; end if;
  if (vs > 0 or vf > 0) and coalesce(new.stakes->>'termos', '') <> 'true' then
    raise exception 'para usar valores é preciso aceitar os termos (18+)';
  end if;
  if tg_op = 'UPDATE' and hoje >= old.start_date then
    if coalesce(nullif(old.stakes->>'semana_valor', '')::numeric, 0) <> vs
       or coalesce(nullif(old.stakes->>'final_valor', '')::numeric, 0) <> vf then
      raise exception 'os valores ficam travados depois que o desafio começa';
    end if;
  end if;
  return new;
end;
$$;
create or replace trigger challenges_stakes_check before insert or update of stakes on public.challenges
  for each row execute function public._challenge_stakes_check();

-- Pontos por semana fechada e por pessoa (mesma regra do app).
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

-- Fecha o que já acabou e grava no livro-caixa (idempotente).
create or replace function public._challenge_close(p_id uuid)
returns int
language plpgsql security definer set search_path = public as $$
declare
  ch public.challenges;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  vs int; vf int; n int := 0; k int;
begin
  select * into ch from public.challenges where id = p_id;
  if not found then return 0; end if;
  vs := round(coalesce(nullif(ch.stakes->>'semana_valor', '')::numeric, 0) * 100)::int;
  vf := round(coalesce(nullif(ch.stakes->>'final_valor', '')::numeric, 0) * 100)::int;

  if vs > 0 then
    with p as (select * from public._challenge_pts(p_id)),
    agg as (
      select week_idx, max(pts) mx, min(pts) mn from p group by week_idx
      having count(*) >= 2 and max(pts) > min(pts)
    ),
    win as (
      select p.week_idx, p.user_id,
             row_number() over (partition by p.week_idx order by p.user_id) rn,
             count(*) over (partition by p.week_idx) nw
      from p join agg a on a.week_idx = p.week_idx where p.pts = a.mx
    ),
    los as (select p.week_idx, p.user_id from p join agg a on a.week_idx = p.week_idx where p.pts = a.mn)
    insert into public.challenge_ledger (challenge_id, kind, week_idx, from_user, to_user, valor_cents)
    select p_id, 'semana', l.week_idx, l.user_id, w.user_id,
           vs / w.nw + case when w.rn = 1 then vs % w.nw else 0 end
    from los l join win w on w.week_idx = l.week_idx
    where vs / w.nw + case when w.rn = 1 then vs % w.nw else 0 end > 0
    on conflict do nothing;
    get diagnostics k = row_count; n := n + k;
  end if;

  -- Final: só quando a última semana já fechou.
  if vf > 0 and ch.start_date + ch.weeks * 7 < hoje then
    with p as (
      select user_id, sum(pts)::int pts, sum(cnt)::int trein from public._challenge_pts(p_id) group by user_id
    ),
    top as (select * from p order by pts desc, trein desc limit 1),
    camp as (
      select p.user_id, row_number() over (order by p.user_id) rn, count(*) over () nc
      from p join top t on t.pts = p.pts and t.trein = p.trein
    )
    insert into public.challenge_ledger (challenge_id, kind, week_idx, from_user, to_user, valor_cents)
    select p_id, 'final', -1, p.user_id, c.user_id, vf / c.nc + case when c.rn = 1 then vf % c.nc else 0 end
    from p cross join camp c
    where p.user_id not in (select user_id from camp)
      and vf / c.nc + case when c.rn = 1 then vf % c.nc else 0 end > 0
    on conflict do nothing;
    get diagnostics k = row_count; n := n + k;
  end if;
  return n;
end;
$$;

-- Tela "Acertos": tudo numa chamada (só pra quem participa ou já participou com lançamento).
create or replace function public.challenge_acertos(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v jsonb;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if not (public.is_challenge_member(p_id) or exists (
    select 1 from public.challenge_ledger l where l.challenge_id = p_id and me in (l.from_user, l.to_user)
  )) then raise exception 'você não participa deste desafio'; end if;
  perform public._challenge_close(p_id);
  select jsonb_build_object(
    'semana_valor_cents', round(coalesce(nullif(c.stakes->>'semana_valor', '')::numeric, 0) * 100)::int,
    'final_valor_cents', round(coalesce(nullif(c.stakes->>'final_valor', '')::numeric, 0) * 100)::int,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'week_idx', l.week_idx, 'valor_cents', l.valor_cents,
        'from_user', l.from_user, 'to_user', l.to_user,
        'from_nome', coalesce(nullif(trim(fa.display_name), ''), split_part(fu.email, '@', 1)),
        'to_nome', coalesce(nullif(trim(ta.display_name), ''), split_part(tu.email, '@', 1)),
        'created_at', l.created_at,
        'paid_at', s.paid_at, 'received_at', s.received_at, 'forgiven_at', s.forgiven_at,
        'contested_at', s.contested_at, 'contest_note', s.contest_note,
        'pode_contestar', (l.created_at > now() - interval '48 hours' and s.received_at is null and s.forgiven_at is null)
      ) order by l.created_at desc, l.week_idx desc)
      from public.challenge_ledger l
      join auth.users fu on fu.id = l.from_user
      join auth.users tu on tu.id = l.to_user
      left join public.app_data fa on fa.user_id = l.from_user
      left join public.app_data ta on ta.user_id = l.to_user
      left join public.challenge_acerto_status s on s.ledger_id = l.id
      where l.challenge_id = p_id
    ), '[]'::jsonb)
  ) into v
  from public.challenges c where c.id = p_id;
  return v;
end;
$$;

create or replace function public._acerto_status(p_ledger uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.challenge_acerto_status (ledger_id) values (p_ledger) on conflict do nothing;
$$;

-- Quem deve marca "paguei".
create or replace function public.acerto_paguei(p_ledger uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.challenge_ledger where id = p_ledger and from_user = auth.uid()) then
    raise exception 'só quem deve marca "paguei"';
  end if;
  perform public._acerto_status(p_ledger);
  update public.challenge_acerto_status set paid_at = coalesce(paid_at, now()) where ledger_id = p_ledger;
end;
$$;

-- Quem recebe confirma "recebi" (isso quita).
create or replace function public.acerto_recebi(p_ledger uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.challenge_ledger where id = p_ledger and to_user = auth.uid()) then
    raise exception 'só quem recebe confirma "recebi"';
  end if;
  perform public._acerto_status(p_ledger);
  update public.challenge_acerto_status
     set received_at = coalesce(received_at, now()), paid_at = coalesce(paid_at, now())
   where ledger_id = p_ledger;
end;
$$;

-- Quem recebe pode perdoar a dívida.
create or replace function public.acerto_perdoar(p_ledger uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.challenge_ledger where id = p_ledger and to_user = auth.uid()) then
    raise exception 'só quem recebe pode perdoar';
  end if;
  perform public._acerto_status(p_ledger);
  update public.challenge_acerto_status set forgiven_at = coalesce(forgiven_at, now()) where ledger_id = p_ledger;
end;
$$;

-- Qualquer um dos dois contesta em até 48h do lançamento (fica registrado; a conta não muda sozinha).
create or replace function public.acerto_contestar(p_ledger uuid, p_nota text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.challenge_ledger
    where id = p_ledger and auth.uid() in (from_user, to_user) and created_at > now() - interval '48 hours'
  ) then raise exception 'só dá pra contestar em até 48h, por quem está no acerto'; end if;
  perform public._acerto_status(p_ledger);
  update public.challenge_acerto_status
     set contested_at = coalesce(contested_at, now()), contest_note = left(coalesce(p_nota, ''), 300)
   where ledger_id = p_ledger;
end;
$$;

-- Convite mostra as apostas antes de entrar.
create or replace function public.challenge_preview(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v public.challenges;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v from public.challenges where invite_code = upper(trim(p_code));
  if not found then return null; end if;
  return jsonb_build_object(
    'id', v.id, 'nome', v.nome, 'start_date', v.start_date, 'weeks', v.weeks,
    'members', (select count(*) from public.challenge_members where challenge_id = v.id),
    'already_member', exists (select 1 from public.challenge_members where challenge_id = v.id and user_id = auth.uid()),
    'stakes', v.stakes
  );
end;
$$;

revoke all on function public._ledger_imutavel() from public, anon, authenticated;
revoke all on function public._challenge_stakes_check() from public, anon, authenticated;
revoke all on function public._challenge_pts(uuid) from public, anon, authenticated;
revoke all on function public._challenge_close(uuid) from public, anon, authenticated;
revoke all on function public._acerto_status(uuid) from public, anon, authenticated;
revoke all on function public.challenge_acertos(uuid) from public, anon;
revoke all on function public.acerto_paguei(uuid) from public, anon;
revoke all on function public.acerto_recebi(uuid) from public, anon;
revoke all on function public.acerto_perdoar(uuid) from public, anon;
revoke all on function public.acerto_contestar(uuid, text) from public, anon;
grant execute on function public.challenge_acertos(uuid) to authenticated;
grant execute on function public.acerto_paguei(uuid) to authenticated;
grant execute on function public.acerto_recebi(uuid) to authenticated;
grant execute on function public.acerto_perdoar(uuid) to authenticated;
grant execute on function public.acerto_contestar(uuid, text) to authenticated;
