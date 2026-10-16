-- Prêmios P1 (formatos): o criador escolhe, por fase (semana / final), o modo:
--   'ultimo' = só quem fica em último paga valor (dividido entre quem ficou em 1º)
--   'pote'   = todos entram com "valor"; o pote é dividido por colocação (divisao: [100], [70,30] ou [50,30,20])
-- Padrões retrocompatíveis: semana = 'ultimo', final = 'pote' com [100] (cada um paga ao campeão).
-- Soma zero por construção, para qualquer tamanho de grupo. Empate divide a(s) fatia(s) das posições empatadas.
-- Idempotente. Depende de challenge_acertos.sql.

create or replace function public._challenge_stakes_check() returns trigger language plpgsql as $$
declare
  vs numeric := coalesce(nullif(new.stakes->>'semana_valor', '')::numeric, 0);
  vf numeric := coalesce(nullif(new.stakes->>'final_valor', '')::numeric, 0);
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  d jsonb; soma int; ph text;
  chaves text[] := array['semana_valor','final_valor','semana_modo','final_modo','semana_divisao','final_divisao'];
begin
  if vs < 0 or vs > 100 then raise exception 'valor da semana deve ficar entre R$ 0 e R$ 100'; end if;
  if vf < 0 or vf > 100 then raise exception 'valor do final deve ficar entre R$ 0 e R$ 100'; end if;
  foreach ph in array array['semana', 'final'] loop
    if coalesce(new.stakes->>(ph || '_modo'), '') not in ('', 'ultimo', 'pote') then raise exception 'modo inválido'; end if;
    d := new.stakes->(ph || '_divisao');
    if d is not null then
      if jsonb_typeof(d) <> 'array' or jsonb_array_length(d) not between 1 and 3 then raise exception 'divisão inválida'; end if;
      select coalesce(sum(x::int), 0) into soma from jsonb_array_elements_text(d) x;
      if soma <> 100 then raise exception 'a divisão do pote deve somar 100%%'; end if;
    end if;
  end loop;
  if (vs > 0 or vf > 0) and coalesce(new.stakes->>'termos', '') <> 'true' then
    raise exception 'para usar valores é preciso aceitar os termos (18+)';
  end if;
  if tg_op = 'UPDATE' and hoje >= old.start_date then
    if (select jsonb_object_agg(k, old.stakes->k) from unnest(chaves) k where old.stakes ? k) is distinct from
       (select jsonb_object_agg(k, new.stakes->k) from unnest(chaves) k where new.stakes ? k) then
      raise exception 'os valores ficam travados depois que o desafio começa';
    end if;
  end if;
  return new;
end;
$$;

-- Divide um valor entre "devedores" e "credores" (nets em centavos, soma zero).
create or replace function public._challenge_settle(
  p_id uuid, p_kind text, p_week int, p_modo text, p_cents int, p_div int[], p_rows jsonb
) returns int
language plpgsql security definer set search_path = public as $$
declare k int := 0; n int;
begin
  n := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  if n < 2 or p_cents <= 0 then return 0; end if;
  with r as (
    select x.u, x.k1, x.k2 from jsonb_to_recordset(p_rows) as x(u uuid, k1 int, k2 int)
  ),
  rk as (
    select u, k1, k2,
           rank() over (order by k1 desc, k2 desc) as pos,
           count(*) over (partition by k1, k2) as sz,
           row_number() over (order by k1 desc, k2 desc, u) as ord
    from r
  ),
  ultimo as (select max(pos) as mp from rk),
  base as (
    select rk.*,
      case
        when p_modo = 'pote' then
          (select coalesce(sum(d), 0) from unnest(p_div) with ordinality t(d, i) where i between rk.pos and rk.pos + rk.sz - 1)
        else 0 end as shares
    from rk
  ),
  prize0 as (
    select b.*,
      case
        when p_modo = 'pote' then floor((p_cents::numeric * n) * b.shares / (100 * b.sz))::int
        else 0 end as prize
    from base b
  ),
  prize as (
    select p.*,
      case when p_modo = 'pote' and p.ord = 1
           then p.prize + (p_cents * n - (select sum(prize) from prize0)) else p.prize end as prize_f
    from prize0 p
  ),
  net as (
    select u,
      case
        when p_modo = 'pote' then prize_f - p_cents
        else
          case
            when (select count(distinct (k1, k2)) from rk) < 2 then 0
            when pos = (select mp from ultimo) then -p_cents
            when pos = 1 then 0   -- crédito dos vencedores é calculado abaixo
            else 0
          end
      end as v, pos, sz, ord
    from prize
  ),
  -- modo 'ultimo': cada perdedor paga p_cents; vencedores dividem
  nets as (
    select u, ord,
      case
        when p_modo = 'pote' then v
        when v < 0 then v
        when pos = 1 and (select count(distinct (k1, k2)) from rk) >= 2 then
          ((select count(*) from net where v < 0) * p_cents) / sz
          + case when ord = 1 then ((select count(*) from net where v < 0) * p_cents) % sz else 0 end
        else 0
      end as v
    from net
  ),
  deb as (select u, -v as amt from nets where v < 0),
  cre as (select u, v as amt, row_number() over (order by ord) as rn from nets where v > 0),
  tc as (select coalesce(sum(amt), 0) as t from cre),
  parts as (
    select d.u as fu, c.u as tu, c.rn, d.amt as damt,
           floor(d.amt::numeric * c.amt / tc.t)::int as a
    from deb d cross join cre c cross join tc where tc.t > 0
  ),
  fin as (
    select fu, tu,
           a + case when rn = 1 then damt - sum(a) over (partition by fu) else 0 end as amt
    from parts
  )
  insert into public.challenge_ledger (challenge_id, kind, week_idx, from_user, to_user, valor_cents)
  select p_id, p_kind, p_week, fu, tu, amt from fin where amt > 0 and fu <> tu
  on conflict do nothing;
  get diagnostics k = row_count;
  return k;
end;
$$;

create or replace function public._challenge_close(p_id uuid)
returns int
language plpgsql security definer set search_path = public as $$
declare
  ch public.challenges;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  vs int; vf int; n int := 0;
  ms text; mf text; ds int[]; df int[];
  w record;
begin
  select * into ch from public.challenges where id = p_id;
  if not found then return 0; end if;
  vs := round(coalesce(nullif(ch.stakes->>'semana_valor', '')::numeric, 0) * 100)::int;
  vf := round(coalesce(nullif(ch.stakes->>'final_valor', '')::numeric, 0) * 100)::int;
  ms := coalesce(nullif(ch.stakes->>'semana_modo', ''), 'ultimo');
  mf := coalesce(nullif(ch.stakes->>'final_modo', ''), 'pote');
  select coalesce(array_agg(x::int order by ord), array[100]) into ds
    from jsonb_array_elements_text(coalesce(ch.stakes->'semana_divisao', '[100]'::jsonb)) with ordinality t(x, ord);
  select coalesce(array_agg(x::int order by ord), array[100]) into df
    from jsonb_array_elements_text(coalesce(ch.stakes->'final_divisao', '[100]'::jsonb)) with ordinality t(x, ord);

  if vs > 0 then
    for w in
      select week_idx, jsonb_agg(jsonb_build_object('u', user_id, 'k1', pts, 'k2', 0)) as rows
      from public._challenge_pts(p_id) group by week_idx
    loop
      n := n + public._challenge_settle(p_id, 'semana', w.week_idx, ms, vs, ds, w.rows);
    end loop;
  end if;

  if vf > 0 and ch.start_date + ch.weeks * 7 < hoje then
    n := n + public._challenge_settle(p_id, 'final', -1, mf, vf, df, (
      select jsonb_agg(jsonb_build_object('u', user_id, 'k1', pts, 'k2', trein))
      from (select user_id, sum(pts)::int pts, sum(cnt)::int trein from public._challenge_pts(p_id) group by user_id) t
    ));
  end if;
  return n;
end;
$$;

-- Desafios com valores: no máximo 6 pessoas.
create or replace function public.join_challenge(p_code text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_st jsonb; v_n int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select id, stakes into v_id, v_st from public.challenges where invite_code = upper(trim(p_code));
  if v_id is null then raise exception 'convite inválido'; end if;
  select count(*) into v_n from public.challenge_members where challenge_id = v_id and user_id <> auth.uid();
  if v_n >= 6 and (coalesce(nullif(v_st->>'semana_valor', '')::numeric, 0) > 0 or coalesce(nullif(v_st->>'final_valor', '')::numeric, 0) > 0) then
    raise exception 'desafios com valores aceitam até 6 pessoas';
  end if;
  insert into public.challenge_members (challenge_id, user_id) values (v_id, auth.uid())
  on conflict do nothing;
  return v_id;
end;
$$;

revoke all on function public._challenge_settle(uuid, text, int, text, int, int[], jsonb) from public, anon, authenticated;
revoke all on function public._challenge_stakes_check() from public, anon, authenticated;
revoke all on function public._challenge_close(uuid) from public, anon, authenticated;
revoke all on function public.join_challenge(text) from public, anon;
grant execute on function public.join_challenge(text) to authenticated;
