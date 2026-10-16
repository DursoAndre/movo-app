-- Provas na nuvem:
--  1) race_entries: quais provas cada pessoa marcou ("Vou nessa") e a distância (km) que vai correr.
--     Cada pessoa só enxerga e mexe nas próprias linhas.
--  2) shared_races: provas cadastradas por qualquer pessoa, visíveis para todo mundo (sem duplicar:
--     mesmo nome + data + cidade vira a mesma prova). Só entra via função share_race.
--  3) race_participants: quantas pessoas vão em cada prova (e em qual distância), sem mostrar quem.
-- Para esconder uma prova cadastrada errada: update public.shared_races set oculta = true where id = 123;
-- Seguro rodar de novo.

create table if not exists public.race_entries (
  user_id uuid not null references auth.users(id) on delete cascade,
  race_id text not null check (char_length(race_id) between 1 and 200),
  km numeric check (km is null or (km > 0 and km <= 400)),
  created_at timestamptz not null default now(),
  primary key (user_id, race_id)
);

create index if not exists race_entries_race_idx on public.race_entries (race_id);

alter table public.race_entries enable row level security;
grant select, insert, update, delete on public.race_entries to authenticated;

drop policy if exists race_entries_select_own on public.race_entries;
create policy race_entries_select_own on public.race_entries for select to authenticated using (auth.uid() = user_id);
drop policy if exists race_entries_insert_own on public.race_entries;
create policy race_entries_insert_own on public.race_entries for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists race_entries_update_own on public.race_entries;
create policy race_entries_update_own on public.race_entries for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists race_entries_delete_own on public.race_entries;
create policy race_entries_delete_own on public.race_entries for delete to authenticated using (auth.uid() = user_id);

create table if not exists public.shared_races (
  id bigint generated always as identity primary key,
  chave text not null unique,
  nome text not null check (char_length(nome) between 2 and 120),
  data_inicio date not null,
  data_fim date,
  cidade text check (cidade is null or char_length(cidade) <= 80),
  uf text check (uf is null or char_length(uf) <= 2),
  modalidade text not null default 'corrida' check (modalidade in ('corrida', 'hyrox', 'outras')),
  distancias jsonb not null default '[]'::jsonb,
  link_oficial text check (link_oficial is null or (link_oficial ~* '^https?://' and char_length(link_oficial) <= 300)),
  criada_por uuid references auth.users(id) on delete set null,
  oculta boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.shared_races enable row level security;
grant select on public.shared_races to authenticated;

drop policy if exists shared_races_select_visible on public.shared_races;
create policy shared_races_select_visible on public.shared_races for select to authenticated using (not oculta);

-- Cadastra uma prova para todo mundo (ou devolve a que já existe com o mesmo nome + data + cidade).
create or replace function public.share_race(
  p_nome text, p_data date, p_data_fim date, p_cidade text, p_uf text,
  p_modalidade text, p_distancias jsonb, p_link text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  norm text := 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ';
  sem text := 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC';
  k text;
  dist jsonb;
  r public.shared_races;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_nome is null or char_length(trim(p_nome)) < 2 then raise exception 'nome invalido'; end if;
  if p_data is null or p_data < current_date - 1 then raise exception 'data invalida'; end if;
  if (select count(*) from public.shared_races where criada_por = uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'limite diario de provas cadastradas';
  end if;
  k := regexp_replace(lower(translate(trim(p_nome), norm, sem)), '[^a-z0-9]+', '', 'g')
       || '|' || p_data::text || '|' ||
       regexp_replace(lower(translate(coalesce(trim(p_cidade), ''), norm, sem)), '[^a-z0-9]+', '', 'g');
  dist := case when p_distancias is not null and jsonb_typeof(p_distancias) = 'array' and jsonb_array_length(p_distancias) <= 6
               then p_distancias else '[]'::jsonb end;

  insert into public.shared_races (chave, nome, data_inicio, data_fim, cidade, uf, modalidade, distancias, link_oficial, criada_por)
  values (k, left(trim(p_nome), 120), p_data, p_data_fim, nullif(left(trim(coalesce(p_cidade, '')), 80), ''),
          nullif(left(upper(trim(coalesce(p_uf, ''))), 2), ''),
          case when p_modalidade in ('corrida', 'hyrox', 'outras') then p_modalidade else 'corrida' end,
          dist, nullif(left(trim(coalesce(p_link, '')), 300), ''), uid)
  on conflict (chave) do nothing
  returning * into r;

  if r.id is null then
    select * into r from public.shared_races where chave = k;
  end if;
  return (to_jsonb(r) - 'chave' - 'criada_por') || jsonb_build_object('nova', r.criada_por = uid and r.created_at > now() - interval '5 seconds');
end;
$$;

-- Quantas pessoas vão em cada prova (e em qual km), sem identificar ninguém.
create or replace function public.race_participants(p_ids text[])
returns table (race_id text, total bigint, por_km jsonb)
language sql
security definer
set search_path = public
as $$
  select t.race_id, sum(t.n)::bigint as total, jsonb_object_agg(coalesce(t.km::text, '?'), t.n) as por_km
  from (
    select e.race_id, e.km, count(*) as n
    from public.race_entries e
    where auth.uid() is not null and cardinality(p_ids) <= 300 and e.race_id = any(p_ids)
    group by e.race_id, e.km
  ) t
  group by t.race_id;
$$;

revoke all on function public.share_race(text, date, date, text, text, text, jsonb, text) from public, anon;
revoke all on function public.race_participants(text[]) from public, anon;
grant execute on function public.share_race(text, date, date, text, text, text, jsonb, text) to authenticated;
grant execute on function public.race_participants(text[]) to authenticated;

-- Privacidade: quem desliga "aparecer para amigos" some da lista de amigos nas provas
-- e também deixa de ver os amigos. Padrão: ligado (sem linha = visível).
create table if not exists public.race_privacy (
  user_id uuid primary key references auth.users(id) on delete cascade,
  visivel_amigos boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.race_privacy enable row level security;
grant select, insert, update on public.race_privacy to authenticated;
drop policy if exists race_privacy_select_own on public.race_privacy;
create policy race_privacy_select_own on public.race_privacy for select to authenticated using (auth.uid() = user_id);
drop policy if exists race_privacy_insert_own on public.race_privacy;
create policy race_privacy_insert_own on public.race_privacy for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists race_privacy_update_own on public.race_privacy;
create policy race_privacy_update_own on public.race_privacy for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Amigos (pedido aceito, tabela friendships) que marcaram cada prova, com nome e km.
-- Só amigos aparecem com nome; as demais pessoas só entram na contagem de race_participants.
-- Nada volta se quem pergunta desligou a visibilidade; amigos que desligaram não aparecem.
create or replace function public.race_friends(p_ids text[])
returns table (race_id text, user_id uuid, nome text, km numeric)
language sql
security definer
set search_path = public
as $$
  select e.race_id, e.user_id,
         coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)) as nome,
         e.km
  from public.race_entries e
  join auth.users u on u.id = e.user_id
  left join public.app_data a on a.user_id = e.user_id
  where auth.uid() is not null
    and cardinality(p_ids) <= 300
    and e.race_id = any(p_ids)
    and e.user_id <> auth.uid()
    and coalesce((select p.visivel_amigos from public.race_privacy p where p.user_id = auth.uid()), true)
    and coalesce((select p.visivel_amigos from public.race_privacy p where p.user_id = e.user_id), true)
    and exists (
      select 1 from public.friendships f
      where (f.user_a = auth.uid() and f.user_b = e.user_id)
         or (f.user_b = auth.uid() and f.user_a = e.user_id)
    )
  order by e.race_id, nome;
$$;

revoke all on function public.race_friends(text[]) from public, anon;
grant execute on function public.race_friends(text[]) to authenticated;
