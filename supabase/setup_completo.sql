-- Movo: setup completo do banco (gerado por supabase/build_setup.py — não edite; edite os arquivos de supabase/sql/).
-- Para um projeto Supabase NOVO, cole tudo no SQL Editor e rode. Em produção NÃO precisa: tudo já está aplicado.

-- ======================================================================
-- admin_identidade.sql
-- ======================================================================
-- Quem é admin do Movo: lista de contas (por user_id) em movo_admins, em vez do e-mail escrito em cada função.
-- Fica no começo da ordem porque várias funções (inclusive language sql) chamam is_movo_admin()/movo_admin_uid().
-- Trocar o e-mail da conta não tira o acesso (o user_id não muda). Segundo admin: insert into movo_admins.
create table if not exists public.movo_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now());
alter table public.movo_admins enable row level security; -- sem policies: só funções security definer leem
revoke all on public.movo_admins from anon, authenticated;
insert into public.movo_admins(user_id) select id from auth.users where lower(email) = 'ardurso@gmail.com' on conflict do nothing;

create or replace function public.movo_admin_uid(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_uid is not null and exists (select 1 from public.movo_admins a where a.user_id = p_uid)
$$;

create or replace function public.is_movo_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.movo_admin_uid(auth.uid())
$$;

-- ======================================================================
-- base_app_e_amigos.sql
-- ======================================================================
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

-- ======================================================================
-- exercise_gaps_setup.sql
-- ======================================================================
-- Exercícios que as pessoas criaram na hora ("Não achou? Adicionar ...") por não
-- existirem no catálogo. Serve pra revisar de vez em quando no painel de admin e
-- decidir o que entra no catálogo. Só guarda usuário + nome digitado + hora.
-- Seguro rodar de novo.

create table if not exists public.exercise_suggestions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 80),
  created_at timestamptz not null default now()
);

alter table public.exercise_suggestions enable row level security;

grant insert on public.exercise_suggestions to authenticated;

drop policy if exists exercise_suggestions_insert_own on public.exercise_suggestions;
create policy exercise_suggestions_insert_own on public.exercise_suggestions
  for insert to authenticated with check (auth.uid() = user_id);

-- Ranking dos nomes mais pedidos (agrupa ignorando maiúsculas e acentos). Só o admin recebe linhas.
drop function if exists public.admin_exercise_gaps(int);

create function public.admin_exercise_gaps(dias int default 90)
returns table (nome text, vezes bigint, usuarios bigint, ultima timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select min(trim(s.nome)) as nome,
         count(*) as vezes,
         count(distinct s.user_id) as usuarios,
         max(s.created_at) as ultima
  from public.exercise_suggestions s
  where s.created_at >= now() - make_interval(days => dias)
    and public.is_movo_admin()
  group by lower(translate(trim(s.nome), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC'))
  order by count(*) desc, max(s.created_at) desc
  limit 50;
$$;

grant execute on function public.admin_exercise_gaps(int) to authenticated;

-- ======================================================================
-- exercise_gaps_origem.sql
-- ======================================================================
-- De onde veio cada exercício fora do catálogo (v161): 'picker' (digitado na busca), 'import_ficha' (importar ficha do
-- treinador), 'import_historico', 'ia'. Alimenta a revisão do catálogo. Seguro rodar de novo.
alter table public.exercise_suggestions add column if not exists origem text not null default 'picker';
alter table public.exercise_suggestions drop constraint if exists exercise_suggestions_origem_check;
alter table public.exercise_suggestions add constraint exercise_suggestions_origem_check check (origem in ('picker', 'import_ficha', 'import_historico', 'ia'));

-- ======================================================================
-- catalogo_banco.sql
-- ======================================================================
-- Catálogo de exercícios no banco (v162). Seguro rodar de novo.
create or replace function public.cat_norm(t text) returns text language sql immutable as $$
  select trim(regexp_replace(translate(lower(coalesce(t,'')),'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc'),'\s+',' ','g'))
$$;

create or replace function public.is_movo_admin() returns boolean language sql stable security definer set search_path=public as $$
  select public.movo_admin_uid(auth.uid()) -- quem é admin: admin_identidade.sql
$$;

create table if not exists public.catalogo_grupos (
  key text primary key, label text not null, kind text not null default 'muscular' check (kind in ('muscular','outro')),
  ordem int not null default 0, updated_at timestamptz not null default now());
create table if not exists public.catalogo_exercicios (
  id text primary key, nome text not null, grupo_key text not null references public.catalogo_grupos(key),
  series int, repeticoes text, descricao text not null default '', observacoes text not null default '', video_url text not null default '',
  ordem int not null default 0, ativo boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.catalogo_sinonimos (
  id serial primary key, termos text[] not null, updated_at timestamptz not null default now());
create table if not exists public.catalogo_aliases (
  alias_norm text primary key, alias_nome text not null, exercicio_id text not null references public.catalogo_exercicios(id) on delete cascade,
  created_at timestamptz not null default now());
create table if not exists public.exercise_review (
  id bigserial primary key, nome_norm text not null, nome text not null, qtd int not null default 1, usuarios int not null default 1,
  status text not null default 'pendente' check (status in ('pendente','aprovado','reprovado')),
  acao text check (acao in ('alias','novo','ignorar')), proposta jsonb not null default '{}'::jsonb, motivo_ia text,
  comentario_admin text, qtd_na_decisao int, created_at timestamptz not null default now(), decidido_em timestamptz);
create unique index if not exists exercise_review_nome_pend on public.exercise_review(nome_norm) where status='pendente';
create index if not exists exercise_review_nome on public.exercise_review(nome_norm);

alter table public.catalogo_grupos enable row level security;
alter table public.catalogo_exercicios enable row level security;
alter table public.catalogo_sinonimos enable row level security;
alter table public.catalogo_aliases enable row level security;
alter table public.exercise_review enable row level security;
drop policy if exists cat_grupos_read on public.catalogo_grupos; create policy cat_grupos_read on public.catalogo_grupos for select to anon, authenticated using (true);
drop policy if exists cat_ex_read on public.catalogo_exercicios; create policy cat_ex_read on public.catalogo_exercicios for select to anon, authenticated using (ativo);
drop policy if exists cat_sin_read on public.catalogo_sinonimos; create policy cat_sin_read on public.catalogo_sinonimos for select to anon, authenticated using (true);
drop policy if exists cat_ali_read on public.catalogo_aliases; create policy cat_ali_read on public.catalogo_aliases for select to anon, authenticated using (true);
-- exercise_review: sem policy (só via RPC admin / service role)

create or replace function public.catalogo_versao() returns text language sql stable security definer set search_path=public as $$
  select md5(concat_ws('|',
    (select count(*)||coalesce(max(updated_at)::text,'') from catalogo_exercicios),
    (select count(*)||coalesce(max(updated_at)::text,'') from catalogo_grupos),
    (select count(*)||coalesce(max(updated_at)::text,'') from catalogo_sinonimos),
    (select count(*)||coalesce(max(created_at)::text,'') from catalogo_aliases)))
$$;

create or replace function public.catalogo_completo() returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'versao', public.catalogo_versao(),
    'grupos', coalesce((select jsonb_agg(jsonb_build_object('key',key,'label',label,'kind',kind) order by ordem) from catalogo_grupos),'[]'::jsonb),
    'exercicios', coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome,'grupo_key',grupo_key,'series',series,'repeticoes',repeticoes,'descricao',descricao,'observacoes',observacoes,'video_url',video_url) order by ordem, nome) from catalogo_exercicios where ativo),'[]'::jsonb),
    'sinonimos', coalesce((select jsonb_agg(termos order by id) from catalogo_sinonimos),'[]'::jsonb),
    'aliases', coalesce((select jsonb_agg(jsonb_build_object('alias',alias_nome,'norm',alias_norm,'id',exercicio_id)) from catalogo_aliases),'[]'::jsonb))
$$;
grant execute on function public.catalogo_versao() to anon, authenticated;
grant execute on function public.catalogo_completo() to anon, authenticated;
revoke all on function public.is_movo_admin() from public, anon;
grant execute on function public.is_movo_admin() to authenticated;

insert into public.catalogo_grupos(key,label,kind,ordem)
select key,label,kind,ordem from jsonb_to_recordset($j$[{"key":"peito","label":"Peito","kind":"muscular","ordem":1},{"key":"costas","label":"Costas","kind":"muscular","ordem":2},{"key":"ombro","label":"Ombro","kind":"muscular","ordem":3},{"key":"biceps","label":"Bíceps","kind":"muscular","ordem":4},{"key":"triceps","label":"Tríceps","kind":"muscular","ordem":5},{"key":"quad","label":"Quadríceps","kind":"muscular","ordem":6},{"key":"posterior","label":"Posterior de coxa","kind":"muscular","ordem":7},{"key":"gluteoPant","label":"Glúteo & Panturrilha","kind":"muscular","ordem":8},{"key":"abdomen","label":"Abdômen","kind":"muscular","ordem":9},{"key":"cardio","label":"Cardio","kind":"outro","ordem":10},{"key":"mobilidade","label":"Mobilidade","kind":"outro","ordem":11}]$j$::jsonb) as t(key text,label text,kind text,ordem int)
on conflict (key) do nothing;

insert into public.catalogo_exercicios(id,nome,grupo_key,series,repeticoes,video_url,ordem)
select id,nome,grupo_key,series,repeticoes,video_url,ordem from jsonb_to_recordset($j$[{"id":"supino-reto-com-halteres","nome":"Supino reto com halteres","grupo_key":"peito","series":4,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=Cjh2fIMQHk0","ordem":1},{"id":"supino-inclinado-com-halteres","nome":"Supino inclinado com halteres","grupo_key":"peito","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=ZaNyRjpoki8","ordem":2},{"id":"crucifixo-no-cross-over","nome":"Crucifixo no cross-over","grupo_key":"peito","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=_hdQD_E3deE","ordem":3},{"id":"supino-reto-com-barra","nome":"Supino reto com barra","grupo_key":"peito","series":4,"repeticoes":"8-10","video_url":"https://www.youtube.com/watch?v=UHa9U-O09_U","ordem":4},{"id":"supino-declinado-com-halteres","nome":"Supino declinado com halteres","grupo_key":"peito","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=Pf1nDoqx_1A","ordem":5},{"id":"flexao-de-braco","nome":"Flexão de braço","grupo_key":"peito","series":3,"repeticoes":"Até a falha","video_url":"https://www.youtube.com/watch?v=0pkjOk0EiAk","ordem":6},{"id":"peck-deck-voador","nome":"Peck deck (voador)","grupo_key":"peito","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=fgXSA2-o0NM","ordem":7},{"id":"puxada-frente-na-polia","nome":"Puxada frente na polia","grupo_key":"costas","series":4,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=oF-RqXrkZHU","ordem":8},{"id":"remada-baixa-na-polia","nome":"Remada baixa na polia","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=6ml0iz19DPw","ordem":9},{"id":"remada-curvada-com-barra-ou-halteres","nome":"Remada curvada com barra ou halteres","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=e53vSzibkO0","ordem":10},{"id":"barra-fixa-pull-up","nome":"Barra fixa (pull-up)","grupo_key":"costas","series":3,"repeticoes":"Até a falha","video_url":"https://www.youtube.com/watch?v=hxIF6qwBr2M","ordem":11},{"id":"remada-unilateral-com-halteres","nome":"Remada unilateral com halteres","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=dFzUjzfih7k","ordem":12},{"id":"puxada-com-pegada-supinada","nome":"Puxada com pegada supinada","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=ZWlG30BZfEo","ordem":13},{"id":"remada-cavalinho-t-bar","nome":"Remada cavalinho (T-bar)","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=8pR3JoZ0iBU","ordem":14},{"id":"hiperextensao-lombar","nome":"Hiperextensão lombar","grupo_key":"costas","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=ivDB23Kcv-A","ordem":15},{"id":"retracao-escapular-remada-isometrica","nome":"Retração escapular (remada isométrica)","grupo_key":"costas","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=kJm_DqqRoL0","ordem":16},{"id":"desenvolvimento-com-halteres","nome":"Desenvolvimento com halteres","grupo_key":"ombro","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=DFXtzdXN_iY","ordem":17},{"id":"elevacao-lateral-com-halteres","nome":"Elevação lateral com halteres","grupo_key":"ombro","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=ot9nwSC1JnA","ordem":18},{"id":"elevacao-frontal-com-halteres","nome":"Elevação frontal com halteres","grupo_key":"ombro","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=GqZRmCow0rw","ordem":19},{"id":"desenvolvimento-militar-com-barra","nome":"Desenvolvimento militar com barra","grupo_key":"ombro","series":3,"repeticoes":"8-10","video_url":"https://www.youtube.com/watch?v=Y5xpE2K660s","ordem":20},{"id":"remada-alta","nome":"Remada alta","grupo_key":"ombro","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=U-KG4oahSLA","ordem":21},{"id":"face-pull-na-polia","nome":"Face pull na polia","grupo_key":"ombro","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=0Po47vvj9g4","ordem":22},{"id":"rotacao-externa-de-ombro-com-faixa-elastica","nome":"Rotação externa de ombro com faixa elástica","grupo_key":"ombro","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=IVR_xKHr7so","ordem":23},{"id":"elevacao-lateral-de-ombro-com-faixa-elastica","nome":"Elevação lateral de ombro com faixa elástica","grupo_key":"ombro","series":3,"repeticoes":"15","video_url":"https://www.youtube.com/watch?v=54H6OG-99EQ","ordem":24},{"id":"wall-slide-deslize-na-parede","nome":"Wall slide (deslize na parede)","grupo_key":"ombro","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=i_0zLUcE-zk","ordem":25},{"id":"rosca-direta-com-barra-ou-halteres","nome":"Rosca direta com barra ou halteres","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=dc330H9yN3Y","ordem":26},{"id":"rosca-alternada-com-halteres","nome":"Rosca alternada com halteres","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=LpM7dGNzMTo","ordem":27},{"id":"rosca-martelo","nome":"Rosca martelo","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=vm0zV_WQerE","ordem":28},{"id":"rosca-scott-concentrada","nome":"Rosca Scott (concentrada)","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=7ixqAPO6JvU","ordem":29},{"id":"triceps-na-polia-corda","nome":"Tríceps na polia (corda)","grupo_key":"triceps","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=-QGC1cL6ETE","ordem":30},{"id":"triceps-testa-com-barra-ou-halteres","nome":"Tríceps testa (com barra ou halteres)","grupo_key":"triceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=cIqScmVpqnc","ordem":31},{"id":"triceps-frances","nome":"Tríceps francês","grupo_key":"triceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=b_r_LW4HEcM","ordem":32},{"id":"mergulho-no-banco-dips","nome":"Mergulho no banco (dips)","grupo_key":"triceps","series":3,"repeticoes":"Até a falha","video_url":"https://www.youtube.com/watch?v=0326dy_-CzM","ordem":33},{"id":"agachamento-livre-ou-na-maquina","nome":"Agachamento livre ou na máquina","grupo_key":"quad","series":4,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=iGLzCCZr_Xw","ordem":34},{"id":"leg-press-45","nome":"Leg press 45°","grupo_key":"quad","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=DQ4-HXFlKXI","ordem":35},{"id":"cadeira-extensora","nome":"Cadeira extensora","grupo_key":"quad","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=u68RNdfZymA","ordem":36},{"id":"afundo-avanco-com-halteres","nome":"Afundo (avanço) com halteres","grupo_key":"quad","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=rltJymhFtHg","ordem":37},{"id":"agachamento-bulgaro","nome":"Agachamento búlgaro","grupo_key":"quad","series":3,"repeticoes":"8-10 cada perna","video_url":"https://www.youtube.com/watch?v=Fmjj7wFJWRE","ordem":38},{"id":"agachamento-sumo","nome":"Agachamento sumô","grupo_key":"quad","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=vBA3vyOxJv0","ordem":39},{"id":"leg-press-unilateral","nome":"Leg press unilateral","grupo_key":"quad","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=LbKwZIbVYZI","ordem":40},{"id":"extensao-de-joelho-sentado-isometria","nome":"Extensão de joelho sentado (isometria)","grupo_key":"quad","series":3,"repeticoes":"12-15 cada perna","video_url":"https://www.youtube.com/watch?v=Pv5L4V5EezM","ordem":41},{"id":"terminal-knee-extension-com-faixa","nome":"Terminal knee extension com faixa","grupo_key":"quad","series":3,"repeticoes":"15 cada perna","video_url":"https://www.youtube.com/watch?v=3d4pIE9iG04","ordem":42},{"id":"mesa-flexora","nome":"Mesa flexora","grupo_key":"posterior","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=IXg1PQ_5gmw","ordem":43},{"id":"stiff-com-halteres-ou-barra","nome":"Stiff com halteres ou barra","grupo_key":"posterior","series":3,"repeticoes":"10-12","video_url":"https://youtu.be/NP548KPEpMw","ordem":44},{"id":"elevacao-pelvica-hip-thrust","nome":"Elevação pélvica (hip thrust)","grupo_key":"posterior","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=pUdIL5x0fWg","ordem":45},{"id":"good-morning","nome":"Good morning","grupo_key":"posterior","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=YA-h3n9L4YU","ordem":46},{"id":"mesa-flexora-unilateral","nome":"Mesa flexora unilateral","grupo_key":"posterior","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=Y1dQUd6OKHk","ordem":47},{"id":"cadeira-flexora-flexora-sentada","nome":"Cadeira flexora (flexora sentada)","grupo_key":"posterior","series":3,"repeticoes":"12-15","video_url":"","ordem":48},{"id":"cadeira-adutora","nome":"Cadeira adutora","grupo_key":"gluteoPant","series":2,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=XbhmXUYp8hs","ordem":49},{"id":"cadeira-abdutora","nome":"Cadeira abdutora","grupo_key":"gluteoPant","series":2,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=nabhYLtz8Gg","ordem":50},{"id":"panturrilha-em-pe","nome":"Panturrilha em pé","grupo_key":"gluteoPant","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=EILF4iyBxSQ","ordem":51},{"id":"gluteo-na-polia-coice","nome":"Glúteo na polia (coice)","grupo_key":"gluteoPant","series":3,"repeticoes":"12-15 cada perna","video_url":"https://www.youtube.com/watch?v=SqO-VUEak2M","ordem":52},{"id":"step-up","nome":"Step up","grupo_key":"gluteoPant","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=5qjqDHOUh-A","ordem":53},{"id":"panturrilha-sentado","nome":"Panturrilha sentado","grupo_key":"gluteoPant","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=ar8nav0jGoE","ordem":54},{"id":"ponte-de-gluteo-glute-bridge","nome":"Ponte de glúteo (glute bridge)","grupo_key":"gluteoPant","series":3,"repeticoes":"15","video_url":"https://www.youtube.com/watch?v=1satDE63Bwc","ordem":55},{"id":"clamshell-concha-com-mini-band","nome":"Clamshell (concha) com mini band","grupo_key":"gluteoPant","series":3,"repeticoes":"15 cada lado","video_url":"https://www.youtube.com/watch?v=XgKzdYhJp1w","ordem":56},{"id":"prancha","nome":"Prancha","grupo_key":"abdomen","series":3,"repeticoes":"30-45s","video_url":"https://www.youtube.com/watch?v=ffHr8a6DRvU","ordem":57},{"id":"abdominal-na-polia-ou-maquina","nome":"Abdominal na polia ou máquina","grupo_key":"abdomen","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=zp6uK1aE1Lc","ordem":58},{"id":"abdominal-supra-crunch","nome":"Abdominal supra (crunch)","grupo_key":"abdomen","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=MKq4WH-eBAQ","ordem":59},{"id":"elevacao-de-pernas","nome":"Elevação de pernas","grupo_key":"abdomen","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=PBTChAcDnZ4","ordem":60},{"id":"prancha-lateral","nome":"Prancha lateral","grupo_key":"abdomen","series":3,"repeticoes":"20-30s cada lado","video_url":"https://www.youtube.com/watch?v=x2gzR9zzSCw","ordem":61},{"id":"abdominal-bicicleta","nome":"Abdominal bicicleta","grupo_key":"abdomen","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=OnQNhK0Ekgk","ordem":62},{"id":"esteira-caminhada-corrida","nome":"Esteira (caminhada/corrida)","grupo_key":"cardio","series":1,"repeticoes":"15-20 min","video_url":"https://www.youtube.com/watch?v=gC-eX9k2DIw","ordem":63},{"id":"bicicleta-ergometrica","nome":"Bicicleta ergométrica","grupo_key":"cardio","series":1,"repeticoes":"15-20 min","video_url":"https://www.youtube.com/watch?v=TY0f2mgR3GI","ordem":64},{"id":"eliptico","nome":"Elíptico","grupo_key":"cardio","series":1,"repeticoes":"15-20 min","video_url":"https://www.youtube.com/watch?v=Lf2u8UMvI68","ordem":65},{"id":"pular-corda","nome":"Pular corda","grupo_key":"cardio","series":3,"repeticoes":"1-2 min","video_url":"https://www.youtube.com/watch?v=_7cpagB7WUg","ordem":66},{"id":"remo-ergometro","nome":"Remo ergômetro","grupo_key":"cardio","series":1,"repeticoes":"10-15 min","video_url":"https://www.youtube.com/watch?v=A-35F9TR0OA","ordem":67},{"id":"hiit-em-circuito","nome":"HIIT em circuito","grupo_key":"cardio","series":4,"repeticoes":"30s forte / 30s leve","video_url":"https://www.youtube.com/watch?v=9v1hhlsGnJ4","ordem":68},{"id":"alongamento-de-posterior-de-coxa","nome":"Alongamento de posterior de coxa","grupo_key":"mobilidade","series":2,"repeticoes":"30s cada lado","video_url":"https://www.youtube.com/watch?v=GHb1xKvO3NY","ordem":69},{"id":"alongamento-de-peitoral","nome":"Alongamento de peitoral","grupo_key":"mobilidade","series":2,"repeticoes":"30s cada lado","video_url":"https://www.youtube.com/watch?v=u7AFpzWV2I8","ordem":70},{"id":"mobilidade-de-quadril-90-90","nome":"Mobilidade de quadril (90/90)","grupo_key":"mobilidade","series":2,"repeticoes":"8-10 cada lado","video_url":"https://www.youtube.com/watch?v=FM7-7-a0FLg","ordem":71},{"id":"gato-camelo-mobilidade-de-coluna","nome":"Gato-camelo (mobilidade de coluna)","grupo_key":"mobilidade","series":2,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=2of247Kt0tU","ordem":72},{"id":"alongamento-de-panturrilha","nome":"Alongamento de panturrilha","grupo_key":"mobilidade","series":2,"repeticoes":"30s cada lado","video_url":"https://www.youtube.com/watch?v=7SO6QzfBRaE","ordem":73},{"id":"rotacao-de-ombro-com-bastao","nome":"Rotação de ombro com bastão","grupo_key":"mobilidade","series":2,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=YW20zO__f_c","ordem":74},{"id":"mobilidade-de-tornozelo-dorsiflexao-na-parede","nome":"Mobilidade de tornozelo (dorsiflexão na parede)","grupo_key":"mobilidade","series":3,"repeticoes":"10 cada lado","video_url":"https://www.youtube.com/watch?v=_3dMj5JYqQw","ordem":75}]$j$::jsonb) as t(id text,nome text,grupo_key text,series int,repeticoes text,video_url text,ordem int)
on conflict (id) do nothing;

insert into public.catalogo_sinonimos(termos)
select array(select jsonb_array_elements_text(e)) from jsonb_array_elements($j$[["cadeira flexora","mesa flexora","flexora","leg curl"],["cadeira extensora","extensora","leg extension"],["leg press","leg 45","pressao de pernas"],["stiff","terra romeno","romanian"],["panturrilha","gemeos","calf"],["abdominal","crunch","abdomen"],["voador","peck deck","peitoral na maquina"],["puxada","pulley","puxador","lat pulldown"],["remada","row"],["rosca","biceps curl"],["triceps","pushdown"],["agachamento","squat"],["supino","bench press"],["elevacao pelvica","hip thrust","ponte de gluteo","glute bridge"],["abdutora","abducao"],["adutora","aducao"],["afundo","avanco","lunge"]]$j$::jsonb) e
where not exists (select 1 from public.catalogo_sinonimos);

-- Revisão do catálogo (v162)
create or replace function public.catalogo_candidatos() returns jsonb language sql stable security definer set search_path=public as $$
  with s as (
    select cat_norm(nome) n, min(nome) nome, count(*)::int qtd, count(distinct user_id)::int usuarios
    from exercise_suggestions group by 1),
  fora as (
    select s.* from s
    where s.n <> ''
      and not exists (select 1 from catalogo_exercicios e where cat_norm(e.nome) = s.n)
      and not exists (select 1 from catalogo_aliases a where a.alias_norm = s.n)
      and not exists (select 1 from exercise_review r where r.nome_norm = s.n and r.status = 'pendente')
      and not exists (select 1 from exercise_review r where r.nome_norm = s.n and r.status in ('aprovado','reprovado')
                      and (r.status = 'aprovado' or s.qtd < greatest(2, coalesce(r.qtd_na_decisao,1) * 2))))
  select jsonb_build_object(
    'candidatos', coalesce((select jsonb_agg(jsonb_build_object('nome_norm',n,'nome',nome,'qtd',qtd,'usuarios',usuarios) order by qtd desc) from fora),'[]'::jsonb),
    'comentarios', coalesce((select jsonb_agg(jsonb_build_object('nome',nome,'acao',acao,'comentario',comentario_admin) order by decidido_em desc) from (select * from exercise_review where status='reprovado' and comentario_admin is not null and comentario_admin <> '' order by decidido_em desc limit 20) c),'[]'::jsonb))
$$;
revoke all on function public.catalogo_candidatos() from public, anon, authenticated;

create or replace function public.admin_revisao_lista() returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'pendentes', coalesce((select jsonb_agg(to_jsonb(r) order by r.qtd desc, r.created_at) from exercise_review r where r.status='pendente'),'[]'::jsonb),
    'decididos', coalesce((select jsonb_agg(to_jsonb(r) order by r.decidido_em desc) from (select * from exercise_review where status<>'pendente' order by decidido_em desc limit 40) r),'[]'::jsonb),
    'sem_revisao', (select count(*)::int from (select cat_norm(nome) n from exercise_suggestions group by 1) s
       where s.n <> '' and not exists (select 1 from catalogo_exercicios e where cat_norm(e.nome)=s.n)
       and not exists (select 1 from catalogo_aliases a where a.alias_norm=s.n)
       and not exists (select 1 from exercise_review r where r.nome_norm=s.n)));
end $$;
grant execute on function public.admin_revisao_lista() to authenticated;

create or replace function public.admin_revisao_decidir(p_id bigint, p_decisao text, p_comentario text default null, p_proposta jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r exercise_review; pr jsonb; ex_id text; g text; nome_ex text;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select * into r from exercise_review where id = p_id and status = 'pendente';
  if not found then raise exception 'revisao nao encontrada'; end if;
  if p_decisao = 'reprovar' then
    update exercise_review set status='reprovado', comentario_admin=left(p_comentario,500), qtd_na_decisao=qtd, decidido_em=now() where id=p_id;
    return jsonb_build_object('ok', true);
  end if;
  if p_decisao <> 'aprovar' then raise exception 'decisao invalida'; end if;
  pr := coalesce(p_proposta, r.proposta);
  if coalesce(pr->>'acao', r.acao) = 'alias' then
    ex_id := pr->>'exercicio_id';
    if not exists (select 1 from catalogo_exercicios where id = ex_id) then raise exception 'exercicio inexistente'; end if;
  else
    nome_ex := trim(pr->>'nome');
    if coalesce(nome_ex,'') = '' then raise exception 'nome obrigatorio'; end if;
    ex_id := trim(both '-' from regexp_replace(cat_norm(nome_ex), '[^a-z0-9]+', '-', 'g'));
    g := pr->>'grupo_key';
    if coalesce(pr->>'grupo_novo','') <> '' then
      g := trim(both '-' from regexp_replace(cat_norm(pr->>'grupo_novo'), '[^a-z0-9]+', '-', 'g'));
      insert into catalogo_grupos(key,label,kind,ordem) values (g, pr->>'grupo_novo', 'muscular', (select coalesce(max(ordem),0)+1 from catalogo_grupos)) on conflict (key) do nothing;
    end if;
    if not exists (select 1 from catalogo_grupos where key = g) then raise exception 'grupo invalido'; end if;
    insert into catalogo_exercicios(id,nome,grupo_key,series,repeticoes,descricao,observacoes,video_url,ordem)
    values (ex_id, nome_ex, g, coalesce((pr->>'series')::int,3), coalesce(nullif(pr->>'repeticoes',''),'10-12'),
            coalesce(pr->>'descricao',''), coalesce(pr->>'observacoes',''), coalesce(pr->>'video_url',''),
            (select coalesce(max(ordem),0)+1 from catalogo_exercicios))
    on conflict (id) do nothing;
  end if;
  insert into catalogo_aliases(alias_norm, alias_nome, exercicio_id) values (r.nome_norm, r.nome, ex_id)
  on conflict (alias_norm) do update set exercicio_id = excluded.exercicio_id, alias_nome = excluded.alias_nome;
  update exercise_review set status='aprovado', comentario_admin=left(p_comentario,500), proposta=pr, decidido_em=now() where id=p_id;
  return jsonb_build_object('ok', true, 'exercicio_id', ex_id);
end $$;
grant execute on function public.admin_revisao_decidir(bigint, text, text, jsonb) to authenticated;
revoke all on function public.admin_revisao_lista() from public, anon;
revoke all on function public.admin_revisao_decidir(bigint, text, text, jsonb) from public, anon;

create or replace function public.admin_revisao_reavaliar(p_id bigint) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  -- solta o nome da trava: a próxima revisão volta a considerar esse exercício
  update exercise_review set nome_norm = nome_norm || '#' || id where id = p_id and status = 'reprovado';
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.admin_revisao_reavaliar(bigint) to authenticated;
revoke all on function public.admin_revisao_reavaliar(bigint) from public, anon;

-- ======================================================================
-- catalogo_v2.sql
-- ======================================================================
-- Catálogo de exercícios v2 (20/10/2026): +341 exercícios, grupos Antebraço e Funcional. Seguro rodar de novo.
-- Rodar depois de catalogo_banco.sql. Os novos entram com ordem 100+, depois dos básicos de cada grupo.
insert into public.catalogo_grupos(key,label,kind,ordem) values
  ('antebraco','Antebraço','muscular',6), ('funcional','Funcional','outro',11)
on conflict (key) do nothing;
update public.catalogo_grupos g set ordem = o.ordem, updated_at = now()
from (select key, ordinality::int as ordem from unnest(array['peito', 'costas', 'ombro', 'biceps', 'triceps', 'antebraco', 'quad', 'posterior', 'gluteoPant', 'abdomen', 'funcional', 'cardio', 'mobilidade']::text[]) with ordinality as t(key)) o
where g.key = o.key and g.ordem is distinct from o.ordem;

insert into public.catalogo_exercicios(id,nome,grupo_key,series,repeticoes,video_url,ordem)
select id,nome,grupo_key,series,repeticoes,video_url,ordem from jsonb_to_recordset($j$[{"id": "supino-inclinado-com-barra", "nome": "Supino inclinado com barra", "grupo_key": "peito", "series": 4, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=oZjIQN0YMX0", "ordem": 100}, {"id": "supino-declinado-com-barra", "nome": "Supino declinado com barra", "grupo_key": "peito", "series": 3, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=ifWEwZDWMAw", "ordem": 101}, {"id": "supino-reto-na-maquina", "nome": "Supino reto na máquina", "grupo_key": "peito", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=e-F32H5SF6E", "ordem": 102}, {"id": "supino-inclinado-na-maquina", "nome": "Supino inclinado na máquina", "grupo_key": "peito", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=-jMrp_24tsg", "ordem": 103}, {"id": "supino-reto-na-smith", "nome": "Supino reto na Smith", "grupo_key": "peito", "series": 4, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=z1Oao5-R-k4", "ordem": 104}, {"id": "supino-inclinado-na-smith", "nome": "Supino inclinado na Smith", "grupo_key": "peito", "series": 3, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=D_h6XI_YxhA", "ordem": 105}, {"id": "supino-com-halteres-pegada-neutra", "nome": "Supino com halteres pegada neutra", "grupo_key": "peito", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=3m7-E2Bcotk", "ordem": 106}, {"id": "supino-no-chao-floor-press", "nome": "Supino no chão (floor press)", "grupo_key": "peito", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=9VxaRYCIqUU", "ordem": 107}, {"id": "crucifixo-reto-com-halteres", "nome": "Crucifixo reto com halteres", "grupo_key": "peito", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=fG2fUgin3Zw", "ordem": 108}, {"id": "crucifixo-inclinado-com-halteres", "nome": "Crucifixo inclinado com halteres", "grupo_key": "peito", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=MEouME-ymto", "ordem": 109}, {"id": "crossover-polia-baixa", "nome": "Crossover polia baixa", "grupo_key": "peito", "series": 3, "repeticoes": "12-15", "video_url": "https://www.youtube.com/watch?v=DFQPzkGfJ_A", "ordem": 110}, {"id": "crucifixo-unilateral-na-polia", "nome": "Crucifixo unilateral na polia", "grupo_key": "peito", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=P2xo1gFwnMY", "ordem": 111}, {"id": "pullover-com-halter", "nome": "Pullover com halter", "grupo_key": "peito", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=OCeOslNnvhw", "ordem": 112}, {"id": "flexao-inclinada-maos-elevadas", "nome": "Flexão inclinada (mãos elevadas)", "grupo_key": "peito", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=COpDKiH4byU", "ordem": 113}, {"id": "flexao-declinada-pes-elevados", "nome": "Flexão declinada (pés elevados)", "grupo_key": "peito", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=BMiBEPtmHMw", "ordem": 114}, {"id": "flexao-de-joelhos", "nome": "Flexão de joelhos", "grupo_key": "peito", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=JMiXotNAWzM", "ordem": 115}, {"id": "flexao-com-palmas-explosiva", "nome": "Flexão com palmas (explosiva)", "grupo_key": "peito", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=BFOtmev-SzM", "ordem": 116}, {"id": "flexao-archer", "nome": "Flexão archer", "grupo_key": "peito", "series": 3, "repeticoes": "6 cada lado", "video_url": "https://www.youtube.com/watch?v=t9h55T4KfEU", "ordem": 117}, {"id": "svend-press", "nome": "Svend press", "grupo_key": "peito", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=4vt6RbvDCE0", "ordem": 118}, {"id": "supino-com-elastico", "nome": "Supino com elástico", "grupo_key": "peito", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=CN0Sk3oiE8Y", "ordem": 119}, {"id": "paralelas-dips", "nome": "Paralelas (dips)", "grupo_key": "peito", "series": 3, "repeticoes": "8-12", "video_url": "https://www.youtube.com/watch?v=tnEq84E6hbo", "ordem": 120}, {"id": "remada-curvada-pegada-supinada-yates", "nome": "Remada curvada pegada supinada (Yates)", "grupo_key": "costas", "series": 4, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=0BfB6WHRks8", "ordem": 121}, {"id": "remada-pendlay", "nome": "Remada Pendlay", "grupo_key": "costas", "series": 4, "repeticoes": "6-8", "video_url": "https://www.youtube.com/watch?v=NXuQZln3xGg", "ordem": 122}, {"id": "remada-na-maquina-sentada", "nome": "Remada na máquina sentada", "grupo_key": "costas", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=WerTQoDj-_g", "ordem": 123}, {"id": "remada-com-apoio-no-peito-chest-supported", "nome": "Remada com apoio no peito (chest supported)", "grupo_key": "costas", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=hpTLYFNVr_s", "ordem": 124}, {"id": "remada-aberta-na-polia", "nome": "Remada aberta na polia", "grupo_key": "costas", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=uEytT5-Wrxk", "ordem": 125}, {"id": "remada-unilateral-na-polia", "nome": "Remada unilateral na polia", "grupo_key": "costas", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=J4a5-GBIp2s", "ordem": 126}, {"id": "remada-na-smith", "nome": "Remada na Smith", "grupo_key": "costas", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=driLkGi3Ovk", "ordem": 127}, {"id": "remada-em-suspensao-trx", "nome": "Remada em suspensão (TRX)", "grupo_key": "costas", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=YL7Z2R2Rhrc", "ordem": 128}, {"id": "remada-invertida-barra-baixa", "nome": "Remada invertida (barra baixa)", "grupo_key": "costas", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=Dn4LAgKA360", "ordem": 129}, {"id": "remada-com-elastico", "nome": "Remada com elástico", "grupo_key": "costas", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=j9KCjIBCG8k", "ordem": 130}, {"id": "remada-landmine", "nome": "Remada landmine", "grupo_key": "costas", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=C9gEMHhz4H0", "ordem": 131}, {"id": "remada-meadows", "nome": "Remada Meadows", "grupo_key": "costas", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=raouwVyQwQ8", "ordem": 132}, {"id": "puxada-atras-da-nuca", "nome": "Puxada atrás da nuca", "grupo_key": "costas", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=Y09q8JO0IwM", "ordem": 133}, {"id": "puxada-com-triangulo-pegada-neutra", "nome": "Puxada com triângulo (pegada neutra)", "grupo_key": "costas", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=ktPLR6vCb1g", "ordem": 134}, {"id": "puxada-unilateral-na-polia", "nome": "Puxada unilateral na polia", "grupo_key": "costas", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=cxJZ-U5qWfc", "ordem": 135}, {"id": "pulldown-braco-reto-pullover-na-polia", "nome": "Pulldown braço reto (pullover na polia)", "grupo_key": "costas", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=V-Z_RntYhZg", "ordem": 136}, {"id": "barra-fixa-supinada-chin-up", "nome": "Barra fixa supinada (chin-up)", "grupo_key": "costas", "series": 3, "repeticoes": "6-10", "video_url": "https://www.youtube.com/watch?v=oNSMi4d6O0M", "ordem": 137}, {"id": "barra-fixa-pegada-neutra", "nome": "Barra fixa pegada neutra", "grupo_key": "costas", "series": 3, "repeticoes": "6-10", "video_url": "https://www.youtube.com/watch?v=pmDEhjDUQeA", "ordem": 138}, {"id": "barra-fixa-assistida", "nome": "Barra fixa assistida", "grupo_key": "costas", "series": 3, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=ncChLdcnZm0", "ordem": 139}, {"id": "barra-fixa-negativa", "nome": "Barra fixa negativa", "grupo_key": "costas", "series": 3, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=6YLKRvAbaY0", "ordem": 140}, {"id": "encolhimento-com-halteres-trapezio", "nome": "Encolhimento com halteres (trapézio)", "grupo_key": "costas", "series": 4, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=cZLgyI2OKcs", "ordem": 141}, {"id": "encolhimento-com-barra", "nome": "Encolhimento com barra", "grupo_key": "costas", "series": 4, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=2zAQKCMeCB4", "ordem": 142}, {"id": "rack-pull", "nome": "Rack pull", "grupo_key": "costas", "series": 3, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=Y99s0dNWpUw", "ordem": 143}, {"id": "superman-extensao-lombar-no-solo", "nome": "Superman (extensão lombar no solo)", "grupo_key": "costas", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=RaHn_82tANI", "ordem": 144}, {"id": "puxada-com-elastico", "nome": "Puxada com elástico", "grupo_key": "costas", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=NYfYY3rZR3w", "ordem": 145}, {"id": "desenvolvimento-na-maquina", "nome": "Desenvolvimento na máquina", "grupo_key": "ombro", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=xxr4_cPZfF0", "ordem": 146}, {"id": "desenvolvimento-arnold", "nome": "Desenvolvimento Arnold", "grupo_key": "ombro", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=Qjv_6bwRlnE", "ordem": 147}, {"id": "desenvolvimento-na-smith", "nome": "Desenvolvimento na Smith", "grupo_key": "ombro", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=kjVYH4k5wDU", "ordem": 148}, {"id": "desenvolvimento-sentado-com-barra", "nome": "Desenvolvimento sentado com barra", "grupo_key": "ombro", "series": 3, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=Uc93l97AOYU", "ordem": 149}, {"id": "desenvolvimento-com-kettlebell", "nome": "Desenvolvimento com kettlebell", "grupo_key": "ombro", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=EWClkjcuj0o", "ordem": 150}, {"id": "elevacao-lateral-na-polia", "nome": "Elevação lateral na polia", "grupo_key": "ombro", "series": 3, "repeticoes": "12-15 cada lado", "video_url": "https://www.youtube.com/watch?v=ze9B6VX4nUs", "ordem": 151}, {"id": "elevacao-lateral-na-maquina", "nome": "Elevação lateral na máquina", "grupo_key": "ombro", "series": 3, "repeticoes": "12-15", "video_url": "https://www.youtube.com/watch?v=jTtN4KpiRLE", "ordem": 152}, {"id": "elevacao-frontal-com-barra", "nome": "Elevação frontal com barra", "grupo_key": "ombro", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=wj7e-leNqGU", "ordem": 153}, {"id": "elevacao-frontal-na-polia", "nome": "Elevação frontal na polia", "grupo_key": "ombro", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=ietkOP004-o", "ordem": 154}, {"id": "elevacao-frontal-com-anilha", "nome": "Elevação frontal com anilha", "grupo_key": "ombro", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=EqIYVm6l5MY", "ordem": 155}, {"id": "crucifixo-inverso-com-halteres", "nome": "Crucifixo inverso com halteres", "grupo_key": "ombro", "series": 3, "repeticoes": "12-15", "video_url": "https://www.youtube.com/watch?v=neiVTL2U5Qo", "ordem": 156}, {"id": "crucifixo-inverso-na-maquina", "nome": "Crucifixo inverso na máquina", "grupo_key": "ombro", "series": 3, "repeticoes": "12-15", "video_url": "https://www.youtube.com/watch?v=eNv7IA_6CIA", "ordem": 157}, {"id": "crucifixo-inverso-na-polia", "nome": "Crucifixo inverso na polia", "grupo_key": "ombro", "series": 3, "repeticoes": "12-15", "video_url": "https://www.youtube.com/watch?v=vVDeOaw1T5g", "ordem": 158}, {"id": "press-landmine-unilateral", "nome": "Press landmine unilateral", "grupo_key": "ombro", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=11cqqGwe4D0", "ordem": 159}, {"id": "elevacao-em-y-t-e-w", "nome": "Elevação em Y, T e W", "grupo_key": "ombro", "series": 2, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=A0FzBIoqppg", "ordem": 160}, {"id": "pull-apart-com-elastico", "nome": "Pull apart com elástico", "grupo_key": "ombro", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=brWneMgR-7k", "ordem": 161}, {"id": "rotacao-interna-de-ombro-com-elastico", "nome": "Rotação interna de ombro com elástico", "grupo_key": "ombro", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=TF8WBsWXScc", "ordem": 162}, {"id": "rotacao-externa-de-ombro-deitado-com-halter", "nome": "Rotação externa de ombro deitado com halter", "grupo_key": "ombro", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=l5pKeePAG9s", "ordem": 163}, {"id": "rotacao-externa-de-ombro-na-polia", "nome": "Rotação externa de ombro na polia", "grupo_key": "ombro", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=FnrGqZSJtFg", "ordem": 164}, {"id": "flexao-pike", "nome": "Flexão pike", "grupo_key": "ombro", "series": 3, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=TQH6U_hfS3Y", "ordem": 165}, {"id": "bottoms-up-press-com-kettlebell", "nome": "Bottoms-up press com kettlebell", "grupo_key": "ombro", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=k5PcL_WIx94", "ordem": 166}, {"id": "flexao-escapular", "nome": "Flexão escapular", "grupo_key": "ombro", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=LeMk15TN0No", "ordem": 167}, {"id": "rosca-direta-na-polia-baixa", "nome": "Rosca direta na polia baixa", "grupo_key": "biceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=zqklqTcOsbo", "ordem": 168}, {"id": "rosca-com-barra-w", "nome": "Rosca com barra W", "grupo_key": "biceps", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=017j7Gbxipo", "ordem": 169}, {"id": "rosca-inclinada-com-halteres", "nome": "Rosca inclinada com halteres", "grupo_key": "biceps", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=ioML_NZH16M", "ordem": 170}, {"id": "rosca-scott-na-maquina", "nome": "Rosca Scott na máquina", "grupo_key": "biceps", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=90sG3CFTz4E", "ordem": 171}, {"id": "rosca-martelo-na-corda-polia", "nome": "Rosca martelo na corda (polia)", "grupo_key": "biceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=CAV3-W0dyeE", "ordem": 172}, {"id": "rosca-martelo-cruzada", "nome": "Rosca martelo cruzada", "grupo_key": "biceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=jgqnyo-TopU", "ordem": 173}, {"id": "rosca-21", "nome": "Rosca 21", "grupo_key": "biceps", "series": 2, "repeticoes": "21", "video_url": "https://www.youtube.com/watch?v=AdSGq31FFds", "ordem": 174}, {"id": "rosca-spider", "nome": "Rosca spider", "grupo_key": "biceps", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=oPFPjcD71Ic", "ordem": 175}, {"id": "rosca-na-polia-alta-duplo-biceps", "nome": "Rosca na polia alta (duplo bíceps)", "grupo_key": "biceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=owR_1o-YX4g", "ordem": 176}, {"id": "rosca-unilateral-na-polia", "nome": "Rosca unilateral na polia", "grupo_key": "biceps", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=peXvZFPfh4U", "ordem": 177}, {"id": "rosca-com-elastico", "nome": "Rosca com elástico", "grupo_key": "biceps", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=pwv9fFtmC_0", "ordem": 178}, {"id": "rosca-zottman", "nome": "Rosca Zottman", "grupo_key": "biceps", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=x8eZaW-bZOE", "ordem": 179}, {"id": "rosca-bayesian", "nome": "Rosca Bayesian", "grupo_key": "biceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=f0Cwx0ezuHU", "ordem": 180}, {"id": "rosca-drag", "nome": "Rosca drag", "grupo_key": "biceps", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=PYh6Xxmgl2E", "ordem": 181}, {"id": "triceps-na-polia-com-barra-reta", "nome": "Tríceps na polia com barra reta", "grupo_key": "triceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=lWfQJ862rP4", "ordem": 182}, {"id": "triceps-na-polia-com-barra-v", "nome": "Tríceps na polia com barra V", "grupo_key": "triceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=LA5-0_DCd1w", "ordem": 183}, {"id": "triceps-unilateral-na-polia", "nome": "Tríceps unilateral na polia", "grupo_key": "triceps", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=L3iEoqC-iUA", "ordem": 184}, {"id": "triceps-testa-na-polia", "nome": "Tríceps testa na polia", "grupo_key": "triceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=EpXB30KCO64", "ordem": 185}, {"id": "triceps-frances-na-polia", "nome": "Tríceps francês na polia", "grupo_key": "triceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=lkEoFfNyzkk", "ordem": 186}, {"id": "triceps-frances-unilateral-com-halter", "nome": "Tríceps francês unilateral com halter", "grupo_key": "triceps", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=eS93gEFXXxo", "ordem": 187}, {"id": "triceps-coice-com-halter", "nome": "Tríceps coice com halter", "grupo_key": "triceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=6nfuyMCEsQs", "ordem": 188}, {"id": "triceps-coice-na-polia", "nome": "Tríceps coice na polia", "grupo_key": "triceps", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=ph5aQsr2FvY", "ordem": 189}, {"id": "supino-fechado-pegada-fechada", "nome": "Supino fechado (pegada fechada)", "grupo_key": "triceps", "series": 4, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=Q74ZvpW5PE8", "ordem": 190}, {"id": "flexao-diamante", "nome": "Flexão diamante", "grupo_key": "triceps", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=RS9qlb7Fl1U", "ordem": 191}, {"id": "mergulho-na-maquina", "nome": "Mergulho na máquina", "grupo_key": "triceps", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=R3Z1oduvWYM", "ordem": 192}, {"id": "triceps-na-maquina", "nome": "Tríceps na máquina", "grupo_key": "triceps", "series": 3, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=b2AP9ils4io", "ordem": 193}, {"id": "triceps-com-elastico", "nome": "Tríceps com elástico", "grupo_key": "triceps", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=UhgOzTWyOVM", "ordem": 194}, {"id": "jm-press", "nome": "JM press", "grupo_key": "triceps", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=09q-wob818M", "ordem": 195}, {"id": "agachamento-frontal-front-squat", "nome": "Agachamento frontal (front squat)", "grupo_key": "quad", "series": 4, "repeticoes": "6-8", "video_url": "https://www.youtube.com/watch?v=Lk2bQ4INdlA", "ordem": 196}, {"id": "agachamento-na-smith", "nome": "Agachamento na Smith", "grupo_key": "quad", "series": 4, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=uCT5wfQIQpk", "ordem": 197}, {"id": "agachamento-hack", "nome": "Agachamento hack", "grupo_key": "quad", "series": 4, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=gEYYCvNI6hI", "ordem": 198}, {"id": "agachamento-pistol", "nome": "Agachamento pistol", "grupo_key": "quad", "series": 3, "repeticoes": "5 cada lado", "video_url": "https://www.youtube.com/watch?v=m72fZPCCTT4", "ordem": 199}, {"id": "agachamento-com-salto-jump-squat", "nome": "Agachamento com salto (jump squat)", "grupo_key": "quad", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=p6miSld2sGs", "ordem": 200}, {"id": "agachamento-goblet", "nome": "Agachamento goblet", "grupo_key": "quad", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=DF9sXArkDUw", "ordem": 201}, {"id": "agachamento-com-pausa", "nome": "Agachamento com pausa", "grupo_key": "quad", "series": 3, "repeticoes": "6", "video_url": "https://www.youtube.com/watch?v=H3jQUNcyHN4", "ordem": 202}, {"id": "agachamento-sissy", "nome": "Agachamento sissy", "grupo_key": "quad", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=RIxWAAufnes", "ordem": 203}, {"id": "agachamento-com-peso-corporal-air-squat", "nome": "Agachamento com peso corporal (air squat)", "grupo_key": "quad", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=ajzahtQpPAg", "ordem": 204}, {"id": "cadeirinha-na-parede-wall-sit", "nome": "Cadeirinha na parede (wall sit)", "grupo_key": "quad", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=p1KsWs_SNjg", "ordem": 205}, {"id": "agachamento-no-caixote-box-squat", "nome": "Agachamento no caixote (box squat)", "grupo_key": "quad", "series": 4, "repeticoes": "6", "video_url": "https://www.youtube.com/watch?v=nbHo41IjpVo", "ordem": 206}, {"id": "agachamento-zercher", "nome": "Agachamento Zercher", "grupo_key": "quad", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=bV-Y_F05Dso", "ordem": 207}, {"id": "leg-press-horizontal", "nome": "Leg press horizontal", "grupo_key": "quad", "series": 4, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=gTo0HfVcLxo", "ordem": 208}, {"id": "afundo-na-smith", "nome": "Afundo na Smith", "grupo_key": "quad", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=X6ebSk82XRM", "ordem": 209}, {"id": "afundo-caminhando-passada", "nome": "Afundo caminhando (passada)", "grupo_key": "quad", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=Vo_ZFfkiZ4o", "ordem": 210}, {"id": "afundo-reverso-avanco-para-tras", "nome": "Afundo reverso (avanço para trás)", "grupo_key": "quad", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=5sl5_wElej4", "ordem": 211}, {"id": "afundo-lateral", "nome": "Afundo lateral", "grupo_key": "quad", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=zV5Vm_hWAwM", "ordem": 212}, {"id": "afundo-com-salto", "nome": "Afundo com salto", "grupo_key": "quad", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=9aXpf7uKQyE", "ordem": 213}, {"id": "afundo-estatico-split-squat", "nome": "Afundo estático (split squat)", "grupo_key": "quad", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=tF6YV-uoKU8", "ordem": 214}, {"id": "afundo-com-barra", "nome": "Afundo com barra", "grupo_key": "quad", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=ECh9lxZAt2E", "ordem": 215}, {"id": "step-down-descida-do-degrau", "nome": "Step down (descida do degrau)", "grupo_key": "quad", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=vyeNJJZJqIo", "ordem": 216}, {"id": "nordico-invertido-reverse-nordic", "nome": "Nórdico invertido (reverse nordic)", "grupo_key": "quad", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=WtHaWnZvllU", "ordem": 217}, {"id": "levantamento-terra-deadlift", "nome": "Levantamento terra (deadlift)", "grupo_key": "posterior", "series": 4, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=QiqUXcz2iyA", "ordem": 218}, {"id": "levantamento-terra-sumo", "nome": "Levantamento terra sumô", "grupo_key": "posterior", "series": 4, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=F1aY4AIim_E", "ordem": 219}, {"id": "levantamento-terra-com-barra-hexagonal-trap-bar", "nome": "Levantamento terra com barra hexagonal (trap bar)", "grupo_key": "posterior", "series": 4, "repeticoes": "6", "video_url": "https://www.youtube.com/watch?v=btgKocUwiVc", "ordem": 220}, {"id": "levantamento-terra-com-kettlebell", "nome": "Levantamento terra com kettlebell", "grupo_key": "posterior", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=H7BjYFSgRz8", "ordem": 221}, {"id": "stiff-unilateral", "nome": "Stiff unilateral", "grupo_key": "posterior", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=Pj9dbkj9Wsc", "ordem": 222}, {"id": "stiff-na-smith", "nome": "Stiff na Smith", "grupo_key": "posterior", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=Lk67BpeTzYo", "ordem": 223}, {"id": "mesa-flexora-em-pe", "nome": "Mesa flexora em pé", "grupo_key": "posterior", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=asgd2_1k7Yw", "ordem": 224}, {"id": "flexora-com-bola-suica", "nome": "Flexora com bola suíça", "grupo_key": "posterior", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=kjaXKoUSY28", "ordem": 225}, {"id": "curl-nordico-nordic-curl", "nome": "Curl nórdico (nordic curl)", "grupo_key": "posterior", "series": 3, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=dBF0m_7tB0E", "ordem": 226}, {"id": "flexora-deslizante-slider", "nome": "Flexora deslizante (slider)", "grupo_key": "posterior", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=jN9OTrEUDe8", "ordem": 227}, {"id": "glute-ham-raise-ghd", "nome": "Glute-ham raise (GHD)", "grupo_key": "posterior", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=TzowfEB3NqI", "ordem": 228}, {"id": "pull-through-na-polia", "nome": "Pull-through na polia", "grupo_key": "posterior", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=i04NloqHYBE", "ordem": 229}, {"id": "cadeira-flexora-unilateral", "nome": "Cadeira flexora unilateral", "grupo_key": "posterior", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=_mchqIf8mKw", "ordem": 230}, {"id": "hip-thrust-na-maquina", "nome": "Hip thrust na máquina", "grupo_key": "gluteoPant", "series": 4, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=OCMjir2i6uU", "ordem": 231}, {"id": "hip-thrust-na-smith", "nome": "Hip thrust na Smith", "grupo_key": "gluteoPant", "series": 4, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=othUJ1jll9g", "ordem": 232}, {"id": "hip-thrust-unilateral", "nome": "Hip thrust unilateral", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=zGxR8AmuOm4", "ordem": 233}, {"id": "hip-thrust-com-elastico", "nome": "Hip thrust com elástico", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=lZkA0sdopYc", "ordem": 234}, {"id": "ponte-de-gluteo-unilateral", "nome": "Ponte de glúteo unilateral", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=HmxvYqmPXfk", "ordem": 235}, {"id": "ponte-de-gluteo-com-elastico", "nome": "Ponte de glúteo com elástico", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=YjBQ3BhPIxg", "ordem": 236}, {"id": "coice-na-maquina-gluteo", "nome": "Coice na máquina (glúteo)", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=iQAHZjXkNi8", "ordem": 237}, {"id": "coice-quatro-apoios-com-caneleira", "nome": "Coice quatro apoios com caneleira", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15 cada lado", "video_url": "https://www.youtube.com/watch?v=RqGQZMusai4", "ordem": 238}, {"id": "coice-com-elastico", "nome": "Coice com elástico", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15 cada lado", "video_url": "https://www.youtube.com/watch?v=p5NbsTL09o0", "ordem": 239}, {"id": "abducao-de-quadril-na-polia", "nome": "Abdução de quadril na polia", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=Qk0X4x03hR0", "ordem": 240}, {"id": "abducao-de-quadril-deitado-de-lado", "nome": "Abdução de quadril deitado de lado", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15 cada lado", "video_url": "https://www.youtube.com/watch?v=XKC3RZ_MrqI", "ordem": 241}, {"id": "caminhada-lateral-com-mini-band", "nome": "Caminhada lateral com mini band", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15 passos cada lado", "video_url": "https://www.youtube.com/watch?v=kEFSeBr4Pq4", "ordem": 242}, {"id": "monster-walk", "nome": "Monster walk", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15 passos", "video_url": "https://www.youtube.com/watch?v=6dn37ultZ8s", "ordem": 243}, {"id": "hidrante-fire-hydrant", "nome": "Hidrante (fire hydrant)", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15 cada lado", "video_url": "https://www.youtube.com/watch?v=W2PNcNCfIF4", "ordem": 244}, {"id": "leg-press-com-pes-altos", "nome": "Leg press com pés altos", "grupo_key": "gluteoPant", "series": 4, "repeticoes": "10-12", "video_url": "https://www.youtube.com/watch?v=Vnb-oj9pB84", "ordem": 245}, {"id": "panturrilha-no-leg-press", "nome": "Panturrilha no leg press", "grupo_key": "gluteoPant", "series": 4, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=aPhesY3Z0RI", "ordem": 246}, {"id": "panturrilha-unilateral-no-degrau", "nome": "Panturrilha unilateral no degrau", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=EhXN6BC8L3Q", "ordem": 247}, {"id": "panturrilha-burro-donkey", "nome": "Panturrilha burro (donkey)", "grupo_key": "gluteoPant", "series": 4, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=COc2cPUfotg", "ordem": 248}, {"id": "salto-de-panturrilha", "nome": "Salto de panturrilha", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "20", "video_url": "", "ordem": 249}, {"id": "tibial-anterior-elevacao-de-ponta-de-pe", "nome": "Tibial anterior (elevação de ponta de pé)", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=qtniUqcwbuc", "ordem": 250}, {"id": "aducao-de-quadril-na-polia", "nome": "Adução de quadril na polia", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=oexco1ihbCg", "ordem": 251}, {"id": "aducao-deitado-de-lado", "nome": "Adução deitado de lado", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=ldUQi0ZdphE", "ordem": 252}, {"id": "aducao-com-bola-entre-os-joelhos", "nome": "Adução com bola entre os joelhos", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=k-uINK1RJXI", "ordem": 253}, {"id": "agachamento-cossaco", "nome": "Agachamento cossaco", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=hQ-AqY_BEmk", "ordem": 254}, {"id": "ponte-sapinho-frog-pump", "nome": "Ponte sapinho (frog pump)", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=9uVdpQOTvEQ", "ordem": 255}, {"id": "step-up-lateral", "nome": "Step up lateral", "grupo_key": "gluteoPant", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=MJTt5WZ7RYU", "ordem": 256}, {"id": "abdominal-infra-elevacao-de-quadril", "nome": "Abdominal infra (elevação de quadril)", "grupo_key": "abdomen", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=oq4Xb_xI618", "ordem": 257}, {"id": "abdominal-canivete-v-up", "nome": "Abdominal canivete (V-up)", "grupo_key": "abdomen", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=UzVne18hplg", "ordem": 258}, {"id": "abdominal-remador", "nome": "Abdominal remador", "grupo_key": "abdomen", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=pNRpcChQmq0", "ordem": 259}, {"id": "abdominal-obliquo-cruzado", "nome": "Abdominal oblíquo (cruzado)", "grupo_key": "abdomen", "series": 3, "repeticoes": "15 cada lado", "video_url": "https://www.youtube.com/watch?v=AK8ZavT9XI0", "ordem": 260}, {"id": "abdominal-com-roda-ab-wheel", "nome": "Abdominal com roda (ab wheel)", "grupo_key": "abdomen", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=pMgnie8K21g", "ordem": 261}, {"id": "elevacao-de-joelhos-na-barra-fixa", "nome": "Elevação de joelhos na barra fixa", "grupo_key": "abdomen", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=crMmq9UwiHo", "ordem": 262}, {"id": "elevacao-de-pernas-na-barra-fixa", "nome": "Elevação de pernas na barra fixa", "grupo_key": "abdomen", "series": 3, "repeticoes": "8-10", "video_url": "https://www.youtube.com/watch?v=f7VmJfgovzo", "ordem": 263}, {"id": "elevacao-de-joelhos-na-cadeira-romana", "nome": "Elevação de joelhos na cadeira romana", "grupo_key": "abdomen", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=fMaUOQpniLE", "ordem": 264}, {"id": "prancha-com-toque-no-ombro", "nome": "Prancha com toque no ombro", "grupo_key": "abdomen", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=BzKKg_vrwrA", "ordem": 265}, {"id": "prancha-com-elevacao-de-perna", "nome": "Prancha com elevação de perna", "grupo_key": "abdomen", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=CFPdqlV7XBc", "ordem": 266}, {"id": "prancha-dinamica-sobe-e-desce", "nome": "Prancha dinâmica (sobe e desce)", "grupo_key": "abdomen", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=44jYz-sfGoY", "ordem": 267}, {"id": "prancha-alta", "nome": "Prancha alta", "grupo_key": "abdomen", "series": 3, "repeticoes": "40s", "video_url": "https://www.youtube.com/watch?v=4Pp59DIwoeQ", "ordem": 268}, {"id": "prancha-com-deslize-body-saw", "nome": "Prancha com deslize (body saw)", "grupo_key": "abdomen", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=R9HJnAdJAUs", "ordem": 269}, {"id": "escalador-mountain-climber", "nome": "Escalador (mountain climber)", "grupo_key": "abdomen", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=Gi5QxKITke4", "ordem": 270}, {"id": "dead-bug-inseto-morto", "nome": "Dead bug (inseto morto)", "grupo_key": "abdomen", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=cejjzAHd4B8", "ordem": 271}, {"id": "bird-dog-cachorro-passaro", "nome": "Bird dog (cachorro-pássaro)", "grupo_key": "abdomen", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=ly5bDJC3OJ0", "ordem": 272}, {"id": "hollow-hold-barquinha", "nome": "Hollow hold (barquinha)", "grupo_key": "abdomen", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=0yPin8hSc8o", "ordem": 273}, {"id": "rotacao-russa-russian-twist", "nome": "Rotação russa (russian twist)", "grupo_key": "abdomen", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=Tpu9jrVSDq8", "ordem": 274}, {"id": "pallof-press", "nome": "Pallof press", "grupo_key": "abdomen", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=91zJZhRx2u0", "ordem": 275}, {"id": "lenhador-na-polia-wood-chop", "nome": "Lenhador na polia (wood chop)", "grupo_key": "abdomen", "series": 3, "repeticoes": "12 cada lado", "video_url": "https://www.youtube.com/watch?v=qzQtXT4L_so", "ordem": 276}, {"id": "rotacao-de-tronco-na-maquina", "nome": "Rotação de tronco na máquina", "grupo_key": "abdomen", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=YR-XvXi7hO4", "ordem": 277}, {"id": "flexao-lateral-de-tronco-com-halter", "nome": "Flexão lateral de tronco com halter", "grupo_key": "abdomen", "series": 3, "repeticoes": "15 cada lado", "video_url": "https://www.youtube.com/watch?v=KZlEkjmMw7c", "ordem": 278}, {"id": "abdominal-declinado", "nome": "Abdominal declinado", "grupo_key": "abdomen", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=TnSKXn1MmHE", "ordem": 279}, {"id": "abdominal-na-bola-suica", "nome": "Abdominal na bola suíça", "grupo_key": "abdomen", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=JhbMxsVpogs", "ordem": 280}, {"id": "tesoura-flutter-kick", "nome": "Tesoura (flutter kick)", "grupo_key": "abdomen", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=fF2VcyduAKQ", "ordem": 281}, {"id": "toque-no-calcanhar-heel-touch", "nome": "Toque no calcanhar (heel touch)", "grupo_key": "abdomen", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=So0jyK7MEJk", "ordem": 282}, {"id": "rollout-na-bola-suica", "nome": "Rollout na bola suíça", "grupo_key": "abdomen", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=nEMqDN1qLIw", "ordem": 283}, {"id": "dragon-flag", "nome": "Dragon flag", "grupo_key": "abdomen", "series": 3, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=QPVuifKlG-4", "ordem": 284}, {"id": "l-sit-sustentacao-em-l", "nome": "L-sit (sustentação em L)", "grupo_key": "abdomen", "series": 3, "repeticoes": "20s", "video_url": "https://www.youtube.com/watch?v=Iwu8rIaWKRo", "ordem": 285}, {"id": "limpador-de-para-brisa-windshield-wiper", "nome": "Limpador de para-brisa (windshield wiper)", "grupo_key": "abdomen", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=af-20PyuwgI", "ordem": 286}, {"id": "vacuum-abdominal", "nome": "Vacuum abdominal", "grupo_key": "abdomen", "series": 3, "repeticoes": "20s", "video_url": "https://www.youtube.com/watch?v=TU9XSn6TYxs", "ordem": 287}, {"id": "abdominal-completo-sit-up", "nome": "Abdominal completo (sit-up)", "grupo_key": "abdomen", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=-BDBDTCzacU", "ordem": 288}, {"id": "escada-simulador-de-escada", "nome": "Escada (simulador de escada)", "grupo_key": "cardio", "series": 1, "repeticoes": "15 min", "video_url": "https://www.youtube.com/watch?v=nal_FtVy8yk", "ordem": 289}, {"id": "bike-de-ar-air-bike", "nome": "Bike de ar (air bike)", "grupo_key": "cardio", "series": 1, "repeticoes": "10 min", "video_url": "https://www.youtube.com/watch?v=hPcOLyfQ0GU", "ordem": 290}, {"id": "spinning-bike-indoor", "nome": "Spinning (bike indoor)", "grupo_key": "cardio", "series": 1, "repeticoes": "40 min", "video_url": "https://www.youtube.com/watch?v=oLuprSZoJjY", "ordem": 291}, {"id": "esteira-inclinada-caminhada", "nome": "Esteira inclinada (caminhada)", "grupo_key": "cardio", "series": 1, "repeticoes": "20 min", "video_url": "https://www.youtube.com/watch?v=FIQuECwhIYo", "ordem": 292}, {"id": "esteira-em-intervalos-tiros", "nome": "Esteira em intervalos (tiros)", "grupo_key": "cardio", "series": 8, "repeticoes": "30s forte / 60s leve", "video_url": "https://www.youtube.com/watch?v=gxqFhZFzTA0", "ordem": 293}, {"id": "corrida-leve-trote", "nome": "Corrida leve (trote)", "grupo_key": "cardio", "series": 1, "repeticoes": "30 min", "video_url": "https://www.youtube.com/watch?v=PQMjDm_WFs0", "ordem": 294}, {"id": "tiros-de-100-m", "nome": "Tiros de 100 m", "grupo_key": "cardio", "series": 6, "repeticoes": "100 m", "video_url": "https://www.youtube.com/watch?v=aMkUQt662Cw", "ordem": 295}, {"id": "tiros-de-400-m", "nome": "Tiros de 400 m", "grupo_key": "cardio", "series": 4, "repeticoes": "400 m", "video_url": "https://www.youtube.com/watch?v=7vsCzWiuD5w", "ordem": 296}, {"id": "tiros-de-800-m", "nome": "Tiros de 800 m", "grupo_key": "cardio", "series": 4, "repeticoes": "800 m", "video_url": "https://www.youtube.com/watch?v=lNhqBZrVvGU", "ordem": 297}, {"id": "corrida-em-subida-hill-sprint", "nome": "Corrida em subida (hill sprint)", "grupo_key": "cardio", "series": 6, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=PPHFu-M4Rzw", "ordem": 298}, {"id": "fartlek", "nome": "Fartlek", "grupo_key": "cardio", "series": 1, "repeticoes": "30 min", "video_url": "https://www.youtube.com/watch?v=tmS0lwvEAr8", "ordem": 299}, {"id": "corrida-vai-e-vem-shuttle-run", "nome": "Corrida vai e vem (shuttle run)", "grupo_key": "cardio", "series": 6, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=pkFJcCmPxqM", "ordem": 300}, {"id": "bicicleta-reclinada", "nome": "Bicicleta reclinada", "grupo_key": "cardio", "series": 1, "repeticoes": "20 min", "video_url": "https://www.youtube.com/watch?v=xmbDumiVYQo", "ordem": 301}, {"id": "polichinelo-jumping-jack", "nome": "Polichinelo (jumping jack)", "grupo_key": "cardio", "series": 3, "repeticoes": "40s", "video_url": "https://www.youtube.com/watch?v=YJbkVbNNops", "ordem": 302}, {"id": "joelho-alto-high-knees", "nome": "Joelho alto (high knees)", "grupo_key": "cardio", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=H38YxUyzDV0", "ordem": 303}, {"id": "chute-no-gluteo-butt-kicks", "nome": "Chute no glúteo (butt kicks)", "grupo_key": "cardio", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=vXVPvY1UbJI", "ordem": 304}, {"id": "skipping", "nome": "Skipping", "grupo_key": "cardio", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=u28Jv3Y4BtE", "ordem": 305}, {"id": "corda-naval-battle-rope", "nome": "Corda naval (battle rope)", "grupo_key": "cardio", "series": 4, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=SUziGC1wU_k", "ordem": 306}, {"id": "boxe-de-sombra-shadow-boxing", "nome": "Boxe de sombra (shadow boxing)", "grupo_key": "cardio", "series": 3, "repeticoes": "2 min", "video_url": "https://www.youtube.com/watch?v=5PTEq3uoW0M", "ordem": 307}, {"id": "saco-de-pancada", "nome": "Saco de pancada", "grupo_key": "cardio", "series": 3, "repeticoes": "2 min", "video_url": "https://www.youtube.com/watch?v=_ixy2NNPPUU", "ordem": 308}, {"id": "natacao", "nome": "Natação", "grupo_key": "cardio", "series": 1, "repeticoes": "30 min", "video_url": "https://www.youtube.com/watch?v=xIuhvUFRW4w", "ordem": 309}, {"id": "caminhada-ao-ar-livre", "nome": "Caminhada ao ar livre", "grupo_key": "cardio", "series": 1, "repeticoes": "40 min", "video_url": "https://www.youtube.com/watch?v=ShtPNGIUoZg", "ordem": 310}, {"id": "esteira-curva", "nome": "Esteira curva", "grupo_key": "cardio", "series": 1, "repeticoes": "15 min", "video_url": "https://www.youtube.com/watch?v=dA3jihPw7c8", "ordem": 311}, {"id": "rosca-inversa", "nome": "Rosca inversa", "grupo_key": "antebraco", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=xuZbpjvKnUk", "ordem": 312}, {"id": "rosca-de-punho-wrist-curl", "nome": "Rosca de punho (wrist curl)", "grupo_key": "antebraco", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=1ZmXT_fpLOI", "ordem": 313}, {"id": "rosca-de-punho-inversa", "nome": "Rosca de punho inversa", "grupo_key": "antebraco", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=zmoy7s5CAsU", "ordem": 314}, {"id": "pegada-estatica-na-barra-dead-hang", "nome": "Pegada estática na barra (dead hang)", "grupo_key": "antebraco", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=RNZEGcwmxdo", "ordem": 315}, {"id": "rosca-inversa-na-polia", "nome": "Rosca inversa na polia", "grupo_key": "antebraco", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=CeJUcDRj0QM", "ordem": 316}, {"id": "giro-de-punho-com-halter", "nome": "Giro de punho com halter", "grupo_key": "antebraco", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=sQz2teCSVVs", "ordem": 317}, {"id": "rolo-de-punho-wrist-roller", "nome": "Rolo de punho (wrist roller)", "grupo_key": "antebraco", "series": 3, "repeticoes": "2", "video_url": "https://www.youtube.com/watch?v=Z08_FA_2q10", "ordem": 318}, {"id": "pinca-com-anilha-plate-pinch", "nome": "Pinça com anilha (plate pinch)", "grupo_key": "antebraco", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=UAEEyglVogw", "ordem": 319}, {"id": "hand-grip-aperto-de-mao", "nome": "Hand grip (aperto de mão)", "grupo_key": "antebraco", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=7c0_BDnrfC8", "ordem": 320}, {"id": "alongamento-de-quadriceps-em-pe", "nome": "Alongamento de quadríceps em pé", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=4sEq7OYYee0", "ordem": 321}, {"id": "alongamento-de-gluteo-figura-4", "nome": "Alongamento de glúteo (figura 4)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=2VE_NLcNMvQ", "ordem": 322}, {"id": "posicao-do-pombo-pigeon", "nome": "Posição do pombo (pigeon)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "45s cada lado", "video_url": "https://www.youtube.com/watch?v=Roqn7rwvUE8", "ordem": 323}, {"id": "alongamento-de-adutores-borboleta", "nome": "Alongamento de adutores (borboleta)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=8xnhUqiILcE", "ordem": 324}, {"id": "alongamento-de-flexores-do-quadril", "nome": "Alongamento de flexores do quadril", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=LkEC8QO0ITk", "ordem": 325}, {"id": "alongamento-de-triceps", "nome": "Alongamento de tríceps", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=ybOKV9EYu_c", "ordem": 326}, {"id": "alongamento-de-biceps", "nome": "Alongamento de bíceps", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=G30Hk9EoYhk", "ordem": 327}, {"id": "alongamento-de-ombro-braco-cruzado", "nome": "Alongamento de ombro (braço cruzado)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "", "ordem": 328}, {"id": "alongamento-de-pescoco", "nome": "Alongamento de pescoço", "grupo_key": "mobilidade", "series": 2, "repeticoes": "20s cada lado", "video_url": "https://www.youtube.com/watch?v=EqNbqY-U5sQ", "ordem": 329}, {"id": "alongamento-de-dorsal", "nome": "Alongamento de dorsal", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=mjytgRfgsnQ", "ordem": 330}, {"id": "alongamento-de-lombar-joelhos-ao-peito", "nome": "Alongamento de lombar (joelhos ao peito)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=uAmC1GhCrvE", "ordem": 331}, {"id": "alongamento-de-antebraco", "nome": "Alongamento de antebraço", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=4UauKt2BC8I", "ordem": 332}, {"id": "postura-da-crianca-child-s-pose", "nome": "Postura da criança (child's pose)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=9ew1pOUIcr8", "ordem": 333}, {"id": "cachorro-olhando-para-baixo-downward-dog", "nome": "Cachorro olhando para baixo (downward dog)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=xDuAZGeb-fc", "ordem": 334}, {"id": "postura-da-cobra-extensao-de-coluna", "nome": "Postura da cobra (extensão de coluna)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=fGIEC44nkBE", "ordem": 335}, {"id": "rotacao-toracica-em-quatro-apoios", "nome": "Rotação torácica em quatro apoios", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=1NCcTlR17rs", "ordem": 336}, {"id": "rotacao-toracica-deitado-open-book", "nome": "Rotação torácica deitado (open book)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=c4RvgBK7GC4", "ordem": 337}, {"id": "mobilidade-de-ombro-com-elastico-pass-through", "nome": "Mobilidade de ombro com elástico (pass-through)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=Hw0GnSXdIrI", "ordem": 338}, {"id": "circulos-de-braco", "nome": "Círculos de braço", "grupo_key": "mobilidade", "series": 2, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=4yPoBcn5ycA", "ordem": 339}, {"id": "agachamento-profundo-deep-squat-hold", "nome": "Agachamento profundo (deep squat hold)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "45s", "video_url": "https://www.youtube.com/watch?v=vfFqegzDKTg", "ordem": 340}, {"id": "alongamento-de-piriforme", "nome": "Alongamento de piriforme", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=BaU_-xSTbmQ", "ordem": 341}, {"id": "world-s-greatest-stretch", "nome": "World's greatest stretch", "grupo_key": "mobilidade", "series": 2, "repeticoes": "5 cada lado", "video_url": "https://www.youtube.com/watch?v=-CiWQ2IvY34", "ordem": 342}, {"id": "inchworm-caminhada-com-as-maos", "nome": "Inchworm (caminhada com as mãos)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=aFkv2m9FTGs", "ordem": 343}, {"id": "circulos-de-quadril", "nome": "Círculos de quadril", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=OvJMG4_nMFc", "ordem": 344}, {"id": "hip-airplane", "nome": "Hip airplane", "grupo_key": "mobilidade", "series": 2, "repeticoes": "6 cada lado", "video_url": "https://www.youtube.com/watch?v=HZW5CahvkIE", "ordem": 345}, {"id": "mobilidade-de-punho", "nome": "Mobilidade de punho", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=6rFORB70eyI", "ordem": 346}, {"id": "mobilidade-toracica-no-rolo", "nome": "Mobilidade torácica no rolo", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=TjPdFHt1SE4", "ordem": 347}, {"id": "rolo-de-espuma-quadriceps", "nome": "Rolo de espuma: quadríceps", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s cada lado", "video_url": "https://www.youtube.com/watch?v=asgAWqwC67c", "ordem": 348}, {"id": "rolo-de-espuma-posterior-de-coxa", "nome": "Rolo de espuma: posterior de coxa", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s cada lado", "video_url": "https://www.youtube.com/watch?v=R8Xxirhp0Hg", "ordem": 349}, {"id": "rolo-de-espuma-gluteo", "nome": "Rolo de espuma: glúteo", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s cada lado", "video_url": "https://www.youtube.com/watch?v=4sJtt9c55MI", "ordem": 350}, {"id": "rolo-de-espuma-dorsal", "nome": "Rolo de espuma: dorsal", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s", "video_url": "https://www.youtube.com/watch?v=x2YczbHH9JQ", "ordem": 351}, {"id": "rolo-de-espuma-panturrilha", "nome": "Rolo de espuma: panturrilha", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s cada lado", "video_url": "https://www.youtube.com/watch?v=nZZe9ai7Vvw", "ordem": 352}, {"id": "liberacao-com-bola-lacrosse-ball", "nome": "Liberação com bola (lacrosse ball)", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s cada lado", "video_url": "https://www.youtube.com/watch?v=s2yj-sdnqMQ", "ordem": 353}, {"id": "liberacao-da-planta-do-pe-com-bola", "nome": "Liberação da planta do pé com bola", "grupo_key": "mobilidade", "series": 1, "repeticoes": "60s cada lado", "video_url": "https://www.youtube.com/watch?v=rR_RTft3P9I", "ordem": 354}, {"id": "alongamento-da-fascia-plantar", "nome": "Alongamento da fáscia plantar", "grupo_key": "mobilidade", "series": 2, "repeticoes": "30s cada lado", "video_url": "https://www.youtube.com/watch?v=UrrzxCt0mkI", "ordem": 355}, {"id": "balanco-de-perna-leg-swing-frontal", "nome": "Balanço de perna (leg swing) frontal", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=KJKoCnhMrYQ", "ordem": 356}, {"id": "balanco-de-perna-leg-swing-lateral", "nome": "Balanço de perna (leg swing) lateral", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=YspbYCAwQ4g", "ordem": 357}, {"id": "passada-com-rotacao-de-tronco", "nome": "Passada com rotação de tronco", "grupo_key": "mobilidade", "series": 2, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=lWj6AFl7hXU", "ordem": 358}, {"id": "mobilidade-de-tornozelo-com-elastico", "nome": "Mobilidade de tornozelo com elástico", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=nw7ZURxakaI", "ordem": 359}, {"id": "rotacao-lombar-deitado", "nome": "Rotação lombar deitado", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=YHAUhoAcXCA", "ordem": 360}, {"id": "respiracao-diafragmatica", "nome": "Respiração diafragmática", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=-alawH0bGW4", "ordem": 361}, {"id": "puxada-escapular-scapular-pull-up", "nome": "Puxada escapular (scapular pull-up)", "grupo_key": "mobilidade", "series": 2, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=305Xrl3KFcM", "ordem": 362}, {"id": "burpee", "nome": "Burpee", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=CrGAnJEfcmY", "ordem": 363}, {"id": "burpee-sobre-a-barra", "nome": "Burpee sobre a barra", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=55LWnnVpN4o", "ordem": 364}, {"id": "burpee-broad-jump-hyrox", "nome": "Burpee broad jump (HYROX)", "grupo_key": "funcional", "series": 1, "repeticoes": "80 m", "video_url": "https://www.youtube.com/watch?v=W5gc1Inyha0", "ordem": 365}, {"id": "burpee-com-salto-na-caixa", "nome": "Burpee com salto na caixa", "grupo_key": "funcional", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=BO794VQhCgo", "ordem": 366}, {"id": "burpee-com-barra-fixa-burpee-pull-up", "nome": "Burpee com barra fixa (burpee pull-up)", "grupo_key": "funcional", "series": 3, "repeticoes": "6", "video_url": "https://www.youtube.com/watch?v=jVzrLDIRqnE", "ordem": 367}, {"id": "thruster-com-barra", "nome": "Thruster com barra", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=ROsQsKVJYZ8", "ordem": 368}, {"id": "thruster-com-halteres", "nome": "Thruster com halteres", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=c9VIcqj_zSQ", "ordem": 369}, {"id": "wall-ball-bola-na-parede", "nome": "Wall ball (bola na parede)", "grupo_key": "funcional", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=i3X-IG9sBJQ", "ordem": 370}, {"id": "power-clean", "nome": "Power clean", "grupo_key": "funcional", "series": 5, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=Blrj4PSY6GQ", "ordem": 371}, {"id": "hang-power-clean", "nome": "Hang power clean", "grupo_key": "funcional", "series": 5, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=xrFPgf5i8Ik", "ordem": 372}, {"id": "hang-clean", "nome": "Hang clean", "grupo_key": "funcional", "series": 5, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=AjADpGtGbo4", "ordem": 373}, {"id": "squat-clean", "nome": "Squat clean", "grupo_key": "funcional", "series": 5, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=fVpuR78myxU", "ordem": 374}, {"id": "clean-and-jerk-arremesso", "nome": "Clean and jerk (arremesso)", "grupo_key": "funcional", "series": 5, "repeticoes": "2", "video_url": "https://www.youtube.com/watch?v=JrZgJC3L2LA", "ordem": 375}, {"id": "power-snatch", "nome": "Power snatch", "grupo_key": "funcional", "series": 5, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=JlFUYGcuyDo", "ordem": 376}, {"id": "hang-power-snatch", "nome": "Hang power snatch", "grupo_key": "funcional", "series": 5, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=vbVIHLWiXjM", "ordem": 377}, {"id": "squat-snatch-arranco", "nome": "Squat snatch (arranco)", "grupo_key": "funcional", "series": 5, "repeticoes": "2", "video_url": "https://www.youtube.com/watch?v=yk4qBW0LdpI", "ordem": 378}, {"id": "snatch-com-halter", "nome": "Snatch com halter", "grupo_key": "funcional", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=IYF0a3k_aZw", "ordem": 379}, {"id": "snatch-com-kettlebell", "nome": "Snatch com kettlebell", "grupo_key": "funcional", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=OVbAImyB1eY", "ordem": 380}, {"id": "push-press", "nome": "Push press", "grupo_key": "funcional", "series": 4, "repeticoes": "6", "video_url": "https://www.youtube.com/watch?v=yAtnbfsiiSs", "ordem": 381}, {"id": "push-jerk", "nome": "Push jerk", "grupo_key": "funcional", "series": 4, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=s65SUf2snU4", "ordem": 382}, {"id": "split-jerk", "nome": "Split jerk", "grupo_key": "funcional", "series": 4, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=pawKWZTMZQM", "ordem": 383}, {"id": "agachamento-overhead-overhead-squat", "nome": "Agachamento overhead (overhead squat)", "grupo_key": "funcional", "series": 4, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=0nwWq4xze4M", "ordem": 384}, {"id": "kettlebell-swing", "nome": "Kettlebell swing", "grupo_key": "funcional", "series": 4, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=MB87gQFA_y0", "ordem": 385}, {"id": "kettlebell-swing-americano", "nome": "Kettlebell swing americano", "grupo_key": "funcional", "series": 4, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=Vq5izU35kmQ", "ordem": 386}, {"id": "kettlebell-swing-unilateral", "nome": "Kettlebell swing unilateral", "grupo_key": "funcional", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=TBnkBQAjeic", "ordem": 387}, {"id": "clean-com-kettlebell", "nome": "Clean com kettlebell", "grupo_key": "funcional", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=Hqj946ZU5vo", "ordem": 388}, {"id": "clean-and-press-com-kettlebell", "nome": "Clean and press com kettlebell", "grupo_key": "funcional", "series": 3, "repeticoes": "6 cada lado", "video_url": "https://www.youtube.com/watch?v=69sR-peSVhg", "ordem": 389}, {"id": "halo-com-kettlebell", "nome": "Halo com kettlebell", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=LEjVh4scVy4", "ordem": 390}, {"id": "levantamento-turco-turkish-get-up", "nome": "Levantamento turco (Turkish get-up)", "grupo_key": "funcional", "series": 3, "repeticoes": "3 cada lado", "video_url": "https://www.youtube.com/watch?v=adAHcFh49Dk", "ordem": 391}, {"id": "windmill-com-kettlebell", "nome": "Windmill com kettlebell", "grupo_key": "funcional", "series": 3, "repeticoes": "6 cada lado", "video_url": "https://www.youtube.com/watch?v=1N1Qs9FO4GU", "ordem": 392}, {"id": "salto-na-caixa-box-jump", "nome": "Salto na caixa (box jump)", "grupo_key": "funcional", "series": 4, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=nWw2iM07rbU", "ordem": 393}, {"id": "salto-sobre-a-caixa-box-jump-over", "nome": "Salto sobre a caixa (box jump over)", "grupo_key": "funcional", "series": 4, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=1nGsGjwazMA", "ordem": 394}, {"id": "salto-em-distancia-broad-jump", "nome": "Salto em distância (broad jump)", "grupo_key": "funcional", "series": 4, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=wOCX8BL-sYY", "ordem": 395}, {"id": "salto-vertical", "nome": "Salto vertical", "grupo_key": "funcional", "series": 4, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=iUUdIz_uou4", "ordem": 396}, {"id": "salto-lateral-skater-jump", "nome": "Salto lateral (skater jump)", "grupo_key": "funcional", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=4bkS2J84qMA", "ordem": 397}, {"id": "tuck-jump", "nome": "Tuck jump", "grupo_key": "funcional", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=FPQwWtJ3Boc", "ordem": 398}, {"id": "depth-jump", "nome": "Depth jump", "grupo_key": "funcional", "series": 3, "repeticoes": "6", "video_url": "https://www.youtube.com/watch?v=bMHL5xqKn3E", "ordem": 399}, {"id": "pular-corda-dupla-double-under", "nome": "Pular corda dupla (double under)", "grupo_key": "funcional", "series": 4, "repeticoes": "30", "video_url": "https://www.youtube.com/watch?v=6ackfoHYHeo", "ordem": 400}, {"id": "toes-to-bar", "nome": "Toes to bar", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=6V69wk46-io", "ordem": 401}, {"id": "knees-to-elbows", "nome": "Knees to elbows", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=mxemkaycS44", "ordem": 402}, {"id": "chest-to-bar", "nome": "Chest to bar", "grupo_key": "funcional", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=RydVit1JIJU", "ordem": 403}, {"id": "barra-fixa-kipping", "nome": "Barra fixa kipping", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=ohws0lsddgY", "ordem": 404}, {"id": "muscle-up-na-barra", "nome": "Muscle-up na barra", "grupo_key": "funcional", "series": 3, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=qbPIHXtHbNM", "ordem": 405}, {"id": "muscle-up-nas-argolas", "nome": "Muscle-up nas argolas", "grupo_key": "funcional", "series": 3, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=S4JSJ0Y3te0", "ordem": 406}, {"id": "mergulho-nas-argolas-ring-dips", "nome": "Mergulho nas argolas (ring dips)", "grupo_key": "funcional", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=6pH265Jr6JY", "ordem": 407}, {"id": "remada-nas-argolas", "nome": "Remada nas argolas", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=SrlEiAWGn2Q", "ordem": 408}, {"id": "subida-na-corda-rope-climb", "nome": "Subida na corda (rope climb)", "grupo_key": "funcional", "series": 3, "repeticoes": "2", "video_url": "https://www.youtube.com/watch?v=DRvnZw71pic", "ordem": 409}, {"id": "flexao-em-parada-de-mao-handstand-push-up", "nome": "Flexão em parada de mão (handstand push-up)", "grupo_key": "funcional", "series": 3, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=SF5e7MVCG28", "ordem": 410}, {"id": "parada-de-mao-handstand-hold", "nome": "Parada de mão (handstand hold)", "grupo_key": "funcional", "series": 3, "repeticoes": "30s", "video_url": "https://www.youtube.com/watch?v=YqrDoz13so4", "ordem": 411}, {"id": "caminhada-de-mao-handstand-walk", "nome": "Caminhada de mão (handstand walk)", "grupo_key": "funcional", "series": 3, "repeticoes": "10 m", "video_url": "https://www.youtube.com/watch?v=Fnp1Z3g4bmc", "ordem": 412}, {"id": "wall-walk", "nome": "Wall walk", "grupo_key": "funcional", "series": 3, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=msuVZ53ka8o", "ordem": 413}, {"id": "hollow-rock", "nome": "Hollow rock", "grupo_key": "funcional", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=X9TsC4KcT5M", "ordem": 414}, {"id": "ghd-sit-up", "nome": "GHD sit-up", "grupo_key": "funcional", "series": 3, "repeticoes": "15", "video_url": "https://www.youtube.com/watch?v=1pbZ8mX2D1U", "ordem": 415}, {"id": "sumo-deadlift-high-pull", "nome": "Sumo deadlift high pull", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=jsagEnYmoIE", "ordem": 416}, {"id": "clean-com-medicine-ball", "nome": "Clean com medicine ball", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=OxuG9MF0epE", "ordem": 417}, {"id": "slam-ball-arremesso-no-chao", "nome": "Slam ball (arremesso no chão)", "grupo_key": "funcional", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=JGX_X-MSM1Q", "ordem": 418}, {"id": "arremesso-lateral-de-medicine-ball", "nome": "Arremesso lateral de medicine ball", "grupo_key": "funcional", "series": 3, "repeticoes": "10 cada lado", "video_url": "https://www.youtube.com/watch?v=P6nEwoXlre0", "ordem": 419}, {"id": "sandbag-no-ombro-sandbag-over-shoulder", "nome": "Sandbag no ombro (sandbag over shoulder)", "grupo_key": "funcional", "series": 3, "repeticoes": "8 cada lado", "video_url": "https://www.youtube.com/watch?v=dxswUh6mVeM", "ordem": 420}, {"id": "carregada-com-sandbag", "nome": "Carregada com sandbag", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=2WXDXZ9m9F4", "ordem": 421}, {"id": "afundo-com-sandbag-hyrox", "nome": "Afundo com sandbag (HYROX)", "grupo_key": "funcional", "series": 1, "repeticoes": "100 m", "video_url": "https://www.youtube.com/watch?v=xYucnNaRfNg", "ordem": 422}, {"id": "agachamento-com-sandbag", "nome": "Agachamento com sandbag", "grupo_key": "funcional", "series": 3, "repeticoes": "12", "video_url": "https://www.youtube.com/watch?v=IbaPKAS3NRg", "ordem": 423}, {"id": "caminhada-do-fazendeiro-farmers-carry", "nome": "Caminhada do fazendeiro (farmers carry)", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=VZ-E-YYbYEg", "ordem": 424}, {"id": "carregada-unilateral-suitcase-carry", "nome": "Carregada unilateral (suitcase carry)", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m cada lado", "video_url": "https://www.youtube.com/watch?v=qRjlkx-vwqw", "ordem": 425}, {"id": "carregada-na-posicao-de-rack", "nome": "Carregada na posição de rack", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=CJ-F_Xg9fJY", "ordem": 426}, {"id": "carregada-acima-da-cabeca-overhead-carry", "nome": "Carregada acima da cabeça (overhead carry)", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=V3gEeMKUfng", "ordem": 427}, {"id": "sled-push-empurrar-treno", "nome": "Sled push (empurrar trenó)", "grupo_key": "funcional", "series": 4, "repeticoes": "25 m", "video_url": "https://www.youtube.com/watch?v=9XRRXaUpnLk", "ordem": 428}, {"id": "sled-pull-puxar-treno-com-corda", "nome": "Sled pull (puxar trenó com corda)", "grupo_key": "funcional", "series": 4, "repeticoes": "25 m", "video_url": "https://www.youtube.com/watch?v=BP6SfBv8Cro", "ordem": 429}, {"id": "arrastar-treno-de-costas", "nome": "Arrastar trenó de costas", "grupo_key": "funcional", "series": 4, "repeticoes": "25 m", "video_url": "https://www.youtube.com/watch?v=jSTKNX3WflE", "ordem": 430}, {"id": "skierg", "nome": "SkiErg", "grupo_key": "funcional", "series": 1, "repeticoes": "1000 m", "video_url": "https://www.youtube.com/watch?v=u7dN5r2OL0g", "ordem": 431}, {"id": "virada-de-pneu-tire-flip", "nome": "Virada de pneu (tire flip)", "grupo_key": "funcional", "series": 3, "repeticoes": "5", "video_url": "https://www.youtube.com/watch?v=o14pB2rG2EQ", "ordem": 432}, {"id": "marreta-no-pneu-sledgehammer", "nome": "Marreta no pneu (sledgehammer)", "grupo_key": "funcional", "series": 3, "repeticoes": "20", "video_url": "https://www.youtube.com/watch?v=Js7D9mid1j8", "ordem": 433}, {"id": "caminhada-do-urso-bear-crawl", "nome": "Caminhada do urso (bear crawl)", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m", "video_url": "https://www.youtube.com/watch?v=O_3rykW-vlI", "ordem": 434}, {"id": "caminhada-de-caranguejo-crab-walk", "nome": "Caminhada de caranguejo (crab walk)", "grupo_key": "funcional", "series": 3, "repeticoes": "20 m", "video_url": "", "ordem": 435}, {"id": "man-maker", "nome": "Man maker", "grupo_key": "funcional", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=cl8Uz37H6ZU", "ordem": 436}, {"id": "devil-press", "nome": "Devil press", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=FvQct1ZsFB4", "ordem": 437}, {"id": "cluster-clean-thruster", "nome": "Cluster (clean + thruster)", "grupo_key": "funcional", "series": 3, "repeticoes": "8", "video_url": "https://www.youtube.com/watch?v=GaRyuzp2dP4", "ordem": 438}, {"id": "agachamento-com-kettlebell-no-rack", "nome": "Agachamento com kettlebell no rack", "grupo_key": "funcional", "series": 3, "repeticoes": "10", "video_url": "https://www.youtube.com/watch?v=AqN3dDNm9tM", "ordem": 439}, {"id": "levantamento-de-pedra-atlas-stone", "nome": "Levantamento de pedra (atlas stone)", "grupo_key": "funcional", "series": 3, "repeticoes": "3", "video_url": "https://www.youtube.com/watch?v=LZCm3mU2GhE", "ordem": 440}]$j$::jsonb) as t(id text,nome text,grupo_key text,series int,repeticoes text,video_url text,ordem int)
on conflict (id) do nothing;

insert into public.catalogo_sinonimos(termos)
select array(select jsonb_array_elements_text(e)) from jsonb_array_elements($j$[["terra", "deadlift", "levantamento terra", "levantamento de terra"], ["terra sumo", "sumo deadlift", "levantamento terra sumo"], ["trap bar", "barra hexagonal", "hex bar", "terra hexagonal"], ["rdl", "romeno", "stiff", "terra romeno"], ["good morning", "bom dia"], ["hip thrust", "elevacao pelvica", "ponte com barra"], ["frog pump", "ponte sapinho", "sapinho"], ["donkey", "burro", "panturrilha burro", "gemeos burro"], ["panturrilha", "gemeos", "calf raise"], ["tibial", "canela", "dorsiflexao"], ["glute ham raise", "ghr", "ghd", "banco romano"], ["nordic", "nordico", "curl nordico", "flexao nordica"], ["reverse nordic", "nordico invertido", "flexao nordica reversa"], ["slider", "flexora deslizante", "hamstring slide"], ["bola suica", "swiss ball", "fitball", "bola de pilates"], ["pull through", "pull-through", "puxada entre as pernas"], ["bulgaro", "split squat bulgaro", "afundo bulgaro"], ["split squat", "afundo estatico", "avanco estatico"], ["walking lunge", "passada", "afundo caminhando", "avanco caminhando"], ["afundo reverso", "avanco para tras", "reverse lunge"], ["afundo lateral", "avanco lateral", "lateral lunge"], ["cossaco", "cossack squat", "agachamento lateral"], ["front squat", "agachamento frontal"], ["hack", "agachamento hack", "hack squat"], ["smith", "barra guiada", "multipower"], ["goblet", "agachamento taca", "goblet squat"], ["sissy", "sissy squat", "agachamento sissy"], ["pistol", "agachamento pistola", "agachamento uma perna"], ["wall sit", "cadeirinha", "cadeira na parede", "agachamento isometrico na parede"], ["jump squat", "agachamento com salto", "agachamento pliometrico"], ["air squat", "agachamento livre sem carga", "agachamento peso do corpo"], ["step down", "descida de degrau"], ["chin-up", "chin up", "barra fixa supinada", "barra supinada"], ["pull-up", "pull up", "barra fixa"], ["barra assistida", "barra fixa assistida", "graviton", "pull-up assistido"], ["yates", "remada yates", "remada curvada supinada"], ["pendlay", "remada pendlay"], ["meadows", "remada meadows"], ["landmine", "mina terrestre", "barra ancorada", "barra no canto"], ["trx", "suspensao", "remada trx", "fita de suspensao"], ["remada invertida", "australian pull-up", "inverted row", "remada na barra baixa"], ["pulldown", "pull-down", "puxada braco reto", "pullover na polia"], ["pullover", "pull over", "pullover com halter"], ["encolhimento", "shrug", "trapezio"], ["rack pull", "terra no rack", "terra parcial"], ["superman", "extensao lombar", "hiperextensao no solo"], ["svend", "svend press", "press com anilha"], ["floor press", "supino no chao", "supino no solo"], ["dips", "paralelas", "mergulho nas paralelas", "paralela"], ["flexao diamante", "diamond push-up", "flexao fechada"], ["flexao archer", "archer push-up", "flexao arqueiro"], ["pike", "flexao pike", "flexao carpada", "pike push-up"], ["hspu", "handstand push-up", "flexao parada de mao", "flexao invertida"], ["arnold", "desenvolvimento arnold", "arnold press"], ["bottoms-up", "bottoms up", "kettlebell invertido"], ["crucifixo inverso", "reverse fly", "fly invertido", "voador inverso", "peck deck inverso"], ["pull apart", "band pull-apart", "abertura com elastico"], ["y t w", "ytw", "elevacao em y"], ["rosca w", "barra w", "barra ez", "ez bar", "rosca barra w"], ["rosca spider", "spider curl"], ["rosca 21", "21s"], ["rosca zottman", "zottman"], ["rosca inversa", "reverse curl", "rosca pegada pronada"], ["rosca de punho", "wrist curl", "rosca punho"], ["wrist roller", "rolo de punho", "enrolador de punho"], ["dead hang", "pendurar na barra", "suspensao na barra"], ["hand grip", "handgrip", "aperto de mao", "pegador de mao"], ["pinca", "plate pinch", "pinca com anilha"], ["triceps pulley", "pulley", "triceps na polia", "triceps barra reta"], ["triceps coice", "kickback", "triceps kickback"], ["jm press", "jm"], ["supino fechado", "close grip bench press", "pegada fechada"], ["abdominal infra", "infra", "elevacao de quadril", "hip raise"], ["canivete", "v-up", "v up", "abdominal v"], ["remador", "abdominal remador", "sit-up remador"], ["ab wheel", "roda abdominal", "rodinha", "rollout"], ["mountain climber", "escalador", "alpinista", "abdominal alpinista"], ["dead bug", "inseto morto", "bicho morto"], ["bird dog", "cachorro passaro", "perdigueiro"], ["hollow", "barquinha", "hollow body", "hollow hold"], ["russian twist", "rotacao russa", "giro russo"], ["pallof", "pallof press", "anti-rotacao"], ["wood chop", "lenhador", "chop", "cortador"], ["dragon flag", "bandeira do dragao"], ["l-sit", "l sit", "sustentacao em l"], ["vacuum", "stomach vacuum", "vacuo abdominal"], ["flutter kick", "tesoura", "pernada"], ["heel touch", "toque no calcanhar"], ["windshield wiper", "limpador de para-brisa", "limpador de parabrisa"], ["toes to bar", "t2b", "pe na barra"], ["knees to elbows", "k2e", "joelho no cotovelo"], ["chest to bar", "c2b", "peito na barra"], ["kipping", "barra kipping", "pull-up kipping"], ["butterfly", "barra butterfly"], ["muscle-up", "muscle up", "mu", "bar muscle-up"], ["ring muscle-up", "muscle-up nas argolas", "argolas"], ["ring dips", "mergulho nas argolas"], ["rope climb", "subida na corda", "escalada na corda"], ["handstand", "parada de mao", "bananeira"], ["handstand walk", "caminhada de mao", "andar de mao"], ["wall walk", "caminhada na parede"], ["burpee", "burpees"], ["burpee broad jump", "bbj", "burpee com salto"], ["bar facing burpee", "burpee sobre a barra", "burpee over the bar"], ["thruster", "thrusters", "agachamento com desenvolvimento"], ["wall ball", "wall balls", "bola na parede", "wallball", "arremesso de bola"], ["clean", "power clean", "arrancada", "cargada"], ["hang clean", "hang power clean", "clean suspenso"], ["squat clean", "clean agachado"], ["clean and jerk", "c&j", "arremesso", "arremesso olimpico"], ["snatch", "arranco", "power snatch"], ["push press", "press com impulso"], ["push jerk", "jerk", "split jerk"], ["overhead squat", "ohs", "agachamento overhead", "agachamento acima da cabeca"], ["kettlebell swing", "swing", "swing com kettlebell", "balanco com kettlebell", "kb swing"], ["american swing", "swing americano"], ["kettlebell halo", "halo"], ["turkish get-up", "tgu", "levantamento turco", "get up"], ["windmill", "moinho", "windmill com kettlebell"], ["box jump", "salto na caixa", "salto no caixote", "salto no box"], ["broad jump", "salto em distancia", "salto horizontal"], ["skater", "skater jump", "salto lateral", "patinador"], ["tuck jump", "salto grupado"], ["depth jump", "salto de profundidade", "drop jump"], ["double under", "du", "corda dupla", "pular corda dupla", "salto duplo de corda"], ["sdhp", "sumo deadlift high pull", "remada alta sumo"], ["slam ball", "ball slam", "arremesso no chao", "bola ao chao"], ["medicine ball", "med ball", "bola medicinal", "medball"], ["sandbag", "saco de areia", "powerbag", "power bag"], ["farmers carry", "farmer walk", "farmers walk", "caminhada do fazendeiro", "carregada"], ["suitcase carry", "carregada unilateral", "maleta"], ["rack carry", "carregada no rack"], ["overhead carry", "carregada acima da cabeca", "waiter walk"], ["sled push", "treno", "treno", "empurrar treno", "prowler"], ["sled pull", "puxar treno", "puxada de treno", "arrastar treno"], ["skierg", "ski erg", "esqui", "ergometro de esqui"], ["tire flip", "virada de pneu", "pneu"], ["sledgehammer", "marreta", "marreta no pneu"], ["bear crawl", "caminhada do urso", "engatinhar"], ["crab walk", "caminhada do caranguejo"], ["man maker", "manmaker"], ["devil press", "devils press", "burpee com halteres"], ["cluster", "clean e thruster"], ["atlas stone", "pedra atlas", "levantamento de pedra"], ["air bike", "assault bike", "echo bike", "bike de ar", "airdyne"], ["escada", "stair climber", "stairmaster", "simulador de escada", "stepmill"], ["spinning", "bike indoor", "ciclismo indoor"], ["hill sprint", "tiro em subida", "corrida em ladeira"], ["shuttle run", "vai e vem", "corrida vai-e-vem"], ["fartlek", "fartleck"], ["tiros", "sprints", "tiro", "corrida de velocidade"], ["trote", "corrida leve", "regenerativo"], ["battle rope", "corda naval", "corda ondulatoria"], ["shadow boxing", "boxe de sombra", "sombra"], ["saco de pancada", "heavy bag", "saco de boxe"], ["jumping jack", "polichinelo"], ["high knees", "joelho alto", "corrida estacionaria"], ["butt kicks", "chute no gluteo", "calcanhar no gluteo"], ["skipping", "skip", "corrida com elevacao"], ["esteira curva", "curved treadmill", "woodway"], ["12-3-30", "esteira inclinada", "caminhada inclinada"], ["pigeon", "pombo", "posicao do pombo"], ["borboleta", "butterfly stretch", "alongamento de adutores"], ["child's pose", "postura da crianca", "balasana", "crianca"], ["downward dog", "cachorro olhando para baixo", "cao olhando para baixo"], ["cobra", "cobra pose", "bhujangasana", "extensao de coluna"], ["thread the needle", "rotacao toracica", "passar a linha na agulha"], ["open book", "livro aberto", "rotacao toracica deitado"], ["pass-through", "pass through", "passagem com elastico", "dislocacao de ombro"], ["deep squat", "malasana", "agachamento profundo", "agachamento de cocoras", "cocoras"], ["piriforme", "piriformis", "alongamento de piriforme"], ["world's greatest stretch", "wgs", "melhor alongamento do mundo"], ["inchworm", "lagarta", "caminhada com as maos"], ["hip circles", "circulos de quadril", "hip cars"], ["hip airplane", "aviao de quadril"], ["foam roller", "rolo de espuma", "liberacao miofascial", "rolinho", "rolo"], ["lacrosse ball", "bolinha", "bola de liberacao", "bola de tenis"], ["fascia plantar", "fascite plantar", "planta do pe"], ["leg swing", "balanco de perna", "balanco de perna"], ["respiracao diafragmatica", "respiracao 90 90", "respiracao abdominal"], ["puxada escapular", "scapular pull-up", "pull-up escapular"], ["flexao escapular", "scapular push-up"], ["mini band", "miniband", "elastico de perna", "faixa curta"], ["monster walk", "caminhada do monstro", "caminhada lateral"], ["fire hydrant", "hidrante", "abducao em quatro apoios"], ["coice", "kickback de gluteo", "gluteo quatro apoios", "glute kickback"], ["abducao", "abdutora deitado", "abducao de quadril"], ["aducao", "aducao de quadril", "adutores"], ["supino na smith", "supino guiado", "bench press smith"]]$j$::jsonb) e
where not exists (select 1 from public.catalogo_sinonimos s where s.termos = array(select jsonb_array_elements_text(e)));
update public.catalogo_exercicios c set video_url = t.v, updated_at = now() from jsonb_to_recordset($j$[{"id":"supino-no-chao-floor-press","v":"https://www.youtube.com/watch?v=9VxaRYCIqUU"},{"id":"crucifixo-unilateral-na-polia","v":"https://www.youtube.com/watch?v=P2xo1gFwnMY"},{"id":"flexao-declinada-pes-elevados","v":"https://www.youtube.com/watch?v=BMiBEPtmHMw"},{"id":"flexao-archer","v":"https://www.youtube.com/watch?v=t9h55T4KfEU"},{"id":"supino-com-elastico","v":"https://www.youtube.com/watch?v=CN0Sk3oiE8Y"},{"id":"remada-aberta-na-polia","v":"https://www.youtube.com/watch?v=uEytT5-Wrxk"},{"id":"remada-na-smith","v":"https://www.youtube.com/watch?v=driLkGi3Ovk"},{"id":"puxada-unilateral-na-polia","v":"https://www.youtube.com/watch?v=cxJZ-U5qWfc"},{"id":"barra-fixa-pegada-neutra","v":"https://www.youtube.com/watch?v=pmDEhjDUQeA"},{"id":"barra-fixa-negativa","v":"https://www.youtube.com/watch?v=6YLKRvAbaY0"},{"id":"encolhimento-com-barra","v":"https://www.youtube.com/watch?v=2zAQKCMeCB4"},{"id":"rack-pull","v":"https://www.youtube.com/watch?v=Y99s0dNWpUw"},{"id":"superman-extensao-lombar-no-solo","v":"https://www.youtube.com/watch?v=RaHn_82tANI"},{"id":"puxada-com-elastico","v":"https://www.youtube.com/watch?v=NYfYY3rZR3w"},{"id":"desenvolvimento-sentado-com-barra","v":"https://www.youtube.com/watch?v=Uc93l97AOYU"},{"id":"press-landmine-unilateral","v":"https://www.youtube.com/watch?v=11cqqGwe4D0"},{"id":"rotacao-interna-de-ombro-com-elastico","v":"https://www.youtube.com/watch?v=TF8WBsWXScc"},{"id":"rotacao-externa-de-ombro-na-polia","v":"https://www.youtube.com/watch?v=FnrGqZSJtFg"},{"id":"bottoms-up-press-com-kettlebell","v":"https://www.youtube.com/watch?v=k5PcL_WIx94"},{"id":"rosca-unilateral-na-polia","v":"https://www.youtube.com/watch?v=peXvZFPfh4U"},{"id":"rosca-zottman","v":"https://www.youtube.com/watch?v=x8eZaW-bZOE"},{"id":"rosca-bayesian","v":"https://www.youtube.com/watch?v=f0Cwx0ezuHU"},{"id":"triceps-frances-unilateral-com-halter","v":"https://www.youtube.com/watch?v=eS93gEFXXxo"},{"id":"triceps-na-maquina","v":"https://www.youtube.com/watch?v=b2AP9ils4io"},{"id":"triceps-com-elastico","v":"https://www.youtube.com/watch?v=UhgOzTWyOVM"},{"id":"jm-press","v":"https://www.youtube.com/watch?v=09q-wob818M"},{"id":"elevacao-frontal-com-anilha","v":"https://www.youtube.com/watch?v=EqIYVm6l5MY"},{"id":"flexao-com-palmas-explosiva","v":"https://www.youtube.com/watch?v=BFOtmev-SzM"},{"id":"rotacao-externa-de-ombro-deitado-com-halter","v":"https://www.youtube.com/watch?v=l5pKeePAG9s"},{"id":"rosca-drag","v":"https://www.youtube.com/watch?v=PYh6Xxmgl2E"},{"id":"desenvolvimento-com-kettlebell","v":"https://www.youtube.com/watch?v=EWClkjcuj0o"},{"id":"agachamento-com-pausa","v":"https://www.youtube.com/watch?v=H3jQUNcyHN4"},{"id":"agachamento-no-caixote-box-squat","v":"https://www.youtube.com/watch?v=nbHo41IjpVo"},{"id":"agachamento-zercher","v":"https://www.youtube.com/watch?v=bV-Y_F05Dso"},{"id":"afundo-com-salto","v":"https://www.youtube.com/watch?v=9aXpf7uKQyE"},{"id":"afundo-com-barra","v":"https://www.youtube.com/watch?v=ECh9lxZAt2E"},{"id":"step-down-descida-do-degrau","v":"https://www.youtube.com/watch?v=vyeNJJZJqIo"},{"id":"levantamento-terra-com-kettlebell","v":"https://www.youtube.com/watch?v=H7BjYFSgRz8"},{"id":"glute-ham-raise-ghd","v":"https://www.youtube.com/watch?v=TzowfEB3NqI"},{"id":"cadeira-flexora-unilateral","v":"https://www.youtube.com/watch?v=_mchqIf8mKw"},{"id":"hip-thrust-com-elastico","v":"https://www.youtube.com/watch?v=lZkA0sdopYc"},{"id":"ponte-de-gluteo-com-elastico","v":"https://www.youtube.com/watch?v=YjBQ3BhPIxg"},{"id":"coice-com-elastico","v":"https://www.youtube.com/watch?v=p5NbsTL09o0"},{"id":"caminhada-lateral-com-mini-band","v":"https://www.youtube.com/watch?v=kEFSeBr4Pq4"},{"id":"monster-walk","v":"https://www.youtube.com/watch?v=6dn37ultZ8s"},{"id":"leg-press-com-pes-altos","v":"https://www.youtube.com/watch?v=Vnb-oj9pB84"},{"id":"aducao-de-quadril-na-polia","v":"https://www.youtube.com/watch?v=oexco1ihbCg"},{"id":"aducao-deitado-de-lado","v":"https://www.youtube.com/watch?v=ldUQi0ZdphE"},{"id":"aducao-com-bola-entre-os-joelhos","v":"https://www.youtube.com/watch?v=k-uINK1RJXI"},{"id":"elevacao-de-joelhos-na-cadeira-romana","v":"https://www.youtube.com/watch?v=fMaUOQpniLE"},{"id":"prancha-com-elevacao-de-perna","v":"https://www.youtube.com/watch?v=CFPdqlV7XBc"},{"id":"prancha-dinamica-sobe-e-desce","v":"https://www.youtube.com/watch?v=44jYz-sfGoY"},{"id":"prancha-alta","v":"https://www.youtube.com/watch?v=4Pp59DIwoeQ"},{"id":"prancha-com-deslize-body-saw","v":"https://www.youtube.com/watch?v=R9HJnAdJAUs"},{"id":"bird-dog-cachorro-passaro","v":"https://www.youtube.com/watch?v=ly5bDJC3OJ0"},{"id":"hollow-hold-barquinha","v":"https://www.youtube.com/watch?v=0yPin8hSc8o"},{"id":"rotacao-de-tronco-na-maquina","v":"https://www.youtube.com/watch?v=YR-XvXi7hO4"},{"id":"abdominal-declinado","v":"https://www.youtube.com/watch?v=TnSKXn1MmHE"},{"id":"abdominal-na-bola-suica","v":"https://www.youtube.com/watch?v=JhbMxsVpogs"},{"id":"tesoura-flutter-kick","v":"https://www.youtube.com/watch?v=fF2VcyduAKQ"},{"id":"toque-no-calcanhar-heel-touch","v":"https://www.youtube.com/watch?v=So0jyK7MEJk"},{"id":"rollout-na-bola-suica","v":"https://www.youtube.com/watch?v=nEMqDN1qLIw"},{"id":"limpador-de-para-brisa-windshield-wiper","v":"https://www.youtube.com/watch?v=af-20PyuwgI"},{"id":"abdominal-completo-sit-up","v":"https://www.youtube.com/watch?v=-BDBDTCzacU"},{"id":"esteira-em-intervalos-tiros","v":"https://www.youtube.com/watch?v=gxqFhZFzTA0"},{"id":"corrida-leve-trote","v":"https://www.youtube.com/watch?v=PQMjDm_WFs0"},{"id":"tiros-de-100-m","v":"https://www.youtube.com/watch?v=aMkUQt662Cw"},{"id":"tiros-de-400-m","v":"https://www.youtube.com/watch?v=7vsCzWiuD5w"},{"id":"tiros-de-800-m","v":"https://www.youtube.com/watch?v=lNhqBZrVvGU"},{"id":"corrida-em-subida-hill-sprint","v":"https://www.youtube.com/watch?v=PPHFu-M4Rzw"},{"id":"fartlek","v":"https://www.youtube.com/watch?v=tmS0lwvEAr8"},{"id":"corrida-vai-e-vem-shuttle-run","v":"https://www.youtube.com/watch?v=pkFJcCmPxqM"},{"id":"bicicleta-reclinada","v":"https://www.youtube.com/watch?v=xmbDumiVYQo"},{"id":"polichinelo-jumping-jack","v":"https://www.youtube.com/watch?v=YJbkVbNNops"},{"id":"chute-no-gluteo-butt-kicks","v":"https://www.youtube.com/watch?v=vXVPvY1UbJI"},{"id":"skipping","v":"https://www.youtube.com/watch?v=u28Jv3Y4BtE"},{"id":"saco-de-pancada","v":"https://www.youtube.com/watch?v=_ixy2NNPPUU"},{"id":"natacao","v":"https://www.youtube.com/watch?v=xIuhvUFRW4w"},{"id":"pegada-estatica-na-barra-dead-hang","v":"https://www.youtube.com/watch?v=RNZEGcwmxdo"},{"id":"giro-de-punho-com-halter","v":"https://www.youtube.com/watch?v=sQz2teCSVVs"},{"id":"pinca-com-anilha-plate-pinch","v":"https://www.youtube.com/watch?v=UAEEyglVogw"},{"id":"alongamento-de-quadriceps-em-pe","v":"https://www.youtube.com/watch?v=4sEq7OYYee0"},{"id":"alongamento-de-gluteo-figura-4","v":"https://www.youtube.com/watch?v=2VE_NLcNMvQ"},{"id":"posicao-do-pombo-pigeon","v":"https://www.youtube.com/watch?v=Roqn7rwvUE8"},{"id":"alongamento-de-adutores-borboleta","v":"https://www.youtube.com/watch?v=8xnhUqiILcE"},{"id":"alongamento-de-flexores-do-quadril","v":"https://www.youtube.com/watch?v=LkEC8QO0ITk"},{"id":"alongamento-de-triceps","v":"https://www.youtube.com/watch?v=ybOKV9EYu_c"},{"id":"alongamento-de-biceps","v":"https://www.youtube.com/watch?v=G30Hk9EoYhk"},{"id":"alongamento-de-pescoco","v":"https://www.youtube.com/watch?v=EqNbqY-U5sQ"},{"id":"alongamento-de-dorsal","v":"https://www.youtube.com/watch?v=mjytgRfgsnQ"},{"id":"alongamento-de-lombar-joelhos-ao-peito","v":"https://www.youtube.com/watch?v=uAmC1GhCrvE"},{"id":"alongamento-de-antebraco","v":"https://www.youtube.com/watch?v=4UauKt2BC8I"},{"id":"postura-da-crianca-child-s-pose","v":"https://www.youtube.com/watch?v=9ew1pOUIcr8"},{"id":"cachorro-olhando-para-baixo-downward-dog","v":"https://www.youtube.com/watch?v=xDuAZGeb-fc"},{"id":"postura-da-cobra-extensao-de-coluna","v":"https://www.youtube.com/watch?v=fGIEC44nkBE"},{"id":"rotacao-toracica-em-quatro-apoios","v":"https://www.youtube.com/watch?v=1NCcTlR17rs"},{"id":"rotacao-toracica-deitado-open-book","v":"https://www.youtube.com/watch?v=c4RvgBK7GC4"},{"id":"mobilidade-de-ombro-com-elastico-pass-through","v":"https://www.youtube.com/watch?v=Hw0GnSXdIrI"},{"id":"circulos-de-braco","v":"https://www.youtube.com/watch?v=4yPoBcn5ycA"},{"id":"agachamento-profundo-deep-squat-hold","v":"https://www.youtube.com/watch?v=vfFqegzDKTg"},{"id":"alongamento-de-piriforme","v":"https://www.youtube.com/watch?v=BaU_-xSTbmQ"},{"id":"inchworm-caminhada-com-as-maos","v":"https://www.youtube.com/watch?v=aFkv2m9FTGs"},{"id":"hip-airplane","v":"https://www.youtube.com/watch?v=HZW5CahvkIE"},{"id":"mobilidade-de-punho","v":"https://www.youtube.com/watch?v=6rFORB70eyI"},{"id":"mobilidade-toracica-no-rolo","v":"https://www.youtube.com/watch?v=TjPdFHt1SE4"},{"id":"rolo-de-espuma-posterior-de-coxa","v":"https://www.youtube.com/watch?v=R8Xxirhp0Hg"},{"id":"rolo-de-espuma-gluteo","v":"https://www.youtube.com/watch?v=4sJtt9c55MI"},{"id":"rolo-de-espuma-dorsal","v":"https://www.youtube.com/watch?v=x2YczbHH9JQ"},{"id":"liberacao-com-bola-lacrosse-ball","v":"https://www.youtube.com/watch?v=s2yj-sdnqMQ"},{"id":"liberacao-da-planta-do-pe-com-bola","v":"https://www.youtube.com/watch?v=rR_RTft3P9I"},{"id":"alongamento-da-fascia-plantar","v":"https://www.youtube.com/watch?v=UrrzxCt0mkI"},{"id":"balanco-de-perna-leg-swing-frontal","v":"https://www.youtube.com/watch?v=KJKoCnhMrYQ"},{"id":"balanco-de-perna-leg-swing-lateral","v":"https://www.youtube.com/watch?v=YspbYCAwQ4g"},{"id":"passada-com-rotacao-de-tronco","v":"https://www.youtube.com/watch?v=lWj6AFl7hXU"},{"id":"mobilidade-de-tornozelo-com-elastico","v":"https://www.youtube.com/watch?v=nw7ZURxakaI"},{"id":"rotacao-lombar-deitado","v":"https://www.youtube.com/watch?v=YHAUhoAcXCA"},{"id":"respiracao-diafragmatica","v":"https://www.youtube.com/watch?v=-alawH0bGW4"},{"id":"puxada-escapular-scapular-pull-up","v":"https://www.youtube.com/watch?v=305Xrl3KFcM"},{"id":"burpee-com-salto-na-caixa","v":"https://www.youtube.com/watch?v=BO794VQhCgo"},{"id":"burpee-com-barra-fixa-burpee-pull-up","v":"https://www.youtube.com/watch?v=jVzrLDIRqnE"},{"id":"clean-and-jerk-arremesso","v":"https://www.youtube.com/watch?v=JrZgJC3L2LA"},{"id":"kettlebell-swing-unilateral","v":"https://www.youtube.com/watch?v=TBnkBQAjeic"},{"id":"clean-and-press-com-kettlebell","v":"https://www.youtube.com/watch?v=69sR-peSVhg"},{"id":"halo-com-kettlebell","v":"https://www.youtube.com/watch?v=LEjVh4scVy4"},{"id":"windmill-com-kettlebell","v":"https://www.youtube.com/watch?v=1N1Qs9FO4GU"},{"id":"salto-sobre-a-caixa-box-jump-over","v":"https://www.youtube.com/watch?v=1nGsGjwazMA"},{"id":"salto-vertical","v":"https://www.youtube.com/watch?v=iUUdIz_uou4"},{"id":"tuck-jump","v":"https://www.youtube.com/watch?v=FPQwWtJ3Boc"},{"id":"depth-jump","v":"https://www.youtube.com/watch?v=bMHL5xqKn3E"},{"id":"knees-to-elbows","v":"https://www.youtube.com/watch?v=mxemkaycS44"},{"id":"chest-to-bar","v":"https://www.youtube.com/watch?v=RydVit1JIJU"},{"id":"remada-nas-argolas","v":"https://www.youtube.com/watch?v=SrlEiAWGn2Q"},{"id":"levantamento-turco-turkish-get-up","v":"https://www.youtube.com/watch?v=adAHcFh49Dk"},{"id":"caminhada-de-mao-handstand-walk","v":"https://www.youtube.com/watch?v=Fnp1Z3g4bmc"},{"id":"hollow-rock","v":"https://www.youtube.com/watch?v=X9TsC4KcT5M"},{"id":"ghd-sit-up","v":"https://www.youtube.com/watch?v=1pbZ8mX2D1U"},{"id":"sumo-deadlift-high-pull","v":"https://www.youtube.com/watch?v=jsagEnYmoIE"},{"id":"clean-com-medicine-ball","v":"https://www.youtube.com/watch?v=OxuG9MF0epE"},{"id":"sandbag-no-ombro-sandbag-over-shoulder","v":"https://www.youtube.com/watch?v=dxswUh6mVeM"},{"id":"carregada-com-sandbag","v":"https://www.youtube.com/watch?v=2WXDXZ9m9F4"},{"id":"agachamento-com-sandbag","v":"https://www.youtube.com/watch?v=IbaPKAS3NRg"},{"id":"carregada-unilateral-suitcase-carry","v":"https://www.youtube.com/watch?v=qRjlkx-vwqw"},{"id":"carregada-na-posicao-de-rack","v":"https://www.youtube.com/watch?v=CJ-F_Xg9fJY"},{"id":"carregada-acima-da-cabeca-overhead-carry","v":"https://www.youtube.com/watch?v=V3gEeMKUfng"},{"id":"caminhada-do-urso-bear-crawl","v":"https://www.youtube.com/watch?v=O_3rykW-vlI"},{"id":"man-maker","v":"https://www.youtube.com/watch?v=cl8Uz37H6ZU"},{"id":"cluster-clean-thruster","v":"https://www.youtube.com/watch?v=GaRyuzp2dP4"},{"id":"agachamento-com-kettlebell-no-rack","v":"https://www.youtube.com/watch?v=AqN3dDNm9tM"},{"id":"levantamento-de-pedra-atlas-stone","v":"https://www.youtube.com/watch?v=LZCm3mU2GhE"},{"id":"world-s-greatest-stretch","v":"https://www.youtube.com/watch?v=-CiWQ2IvY34"},{"id":"arrastar-treno-de-costas","v":"https://www.youtube.com/watch?v=jSTKNX3WflE"},{"id":"marreta-no-pneu-sledgehammer","v":"https://www.youtube.com/watch?v=Js7D9mid1j8"},{"id":"hidrante-fire-hydrant","v":"https://www.youtube.com/watch?v=W2PNcNCfIF4"},{"id":"step-up-lateral","v":"https://www.youtube.com/watch?v=MJTt5WZ7RYU"},{"id":"caminhada-ao-ar-livre","v":"https://www.youtube.com/watch?v=ShtPNGIUoZg"},{"id":"spinning-bike-indoor","v":"https://www.youtube.com/watch?v=oLuprSZoJjY"},{"id":"rolo-de-espuma-quadriceps","v":"https://www.youtube.com/watch?v=asgAWqwC67c"},{"id":"flexora-deslizante-slider","v":"https://www.youtube.com/watch?v=jN9OTrEUDe8"},{"id":"flexora-com-bola-suica","v":"https://www.youtube.com/watch?v=kjaXKoUSY28"},{"id":"circulos-de-quadril","v":"https://www.youtube.com/watch?v=OvJMG4_nMFc"},{"id":"esteira-curva","v":"https://www.youtube.com/watch?v=dA3jihPw7c8"},{"id":"rolo-de-espuma-panturrilha","v":"https://www.youtube.com/watch?v=nZZe9ai7Vvw"},{"id":"elevacao-em-y-t-e-w","v":"https://www.youtube.com/watch?v=A0FzBIoqppg"},{"id":"hang-clean","v":"https://www.youtube.com/watch?v=AjADpGtGbo4"},{"id":"hang-power-snatch","v":"https://www.youtube.com/watch?v=vbVIHLWiXjM"}]$j$::jsonb) as t(id text, v text) where c.id = t.id and c.video_url = '';

-- ======================================================================
-- user_consents.sql
-- ======================================================================
-- Registro do aceite da Política de Privacidade e dos Termos (versão + data). Seguro rodar de novo.
create table if not exists public.user_consents (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  versao text not null,
  aceito_em timestamptz not null default now(),
  unique (user_id, versao)
);
alter table public.user_consents enable row level security;
revoke all on public.user_consents from anon;
grant select, insert on public.user_consents to authenticated;
drop policy if exists user_consents_select_own on public.user_consents;
create policy user_consents_select_own on public.user_consents for select to authenticated using (auth.uid() = user_id);
drop policy if exists user_consents_insert_own on public.user_consents;
create policy user_consents_insert_own on public.user_consents for insert to authenticated with check (auth.uid() = user_id);

-- ======================================================================
-- client_errors_setup.sql
-- ======================================================================
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

-- ======================================================================
-- client_errors_anon_grant.sql
-- ======================================================================
-- client_errors só tinha grant de insert pra authenticated — qualquer log de
-- erro disparado ANTES do login (ex: "sessão sumiu, precisei logar de novo")
-- roda com a role anônima (sem sessão == sem token == role anon no Postgres),
-- então esses inserts vinham falhando silenciosamente, sem erro visível pra
-- ninguém perceber. A policy de RLS já cobre isso (user_id is null libera o
-- insert), só faltava o grant de privilégio na tabela em si.
grant insert on public.client_errors to anon;

-- ======================================================================
-- user_feedback_setup.sql
-- ======================================================================
create table public.user_feedback (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  tipo text not null default 'ideia',
  mensagem text not null,
  contato boolean not null default true,
  versao text,
  lido boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.user_feedback enable row level security;

grant select, insert on public.user_feedback to authenticated;

create policy user_feedback_insert_own on public.user_feedback
  for insert with check (auth.uid() = user_id and char_length(mensagem) between 3 and 2000);

create policy user_feedback_select_own on public.user_feedback
  for select using (auth.uid() = user_id);

create or replace function public.admin_feedback_list(limit_n int default 100)
returns table (id bigint, created_at timestamptz, email text, tipo text, mensagem text, contato boolean, versao text, lido boolean)
language sql
security definer
set search_path = public, auth
as $$
  select f.id, f.created_at, u.email, f.tipo, f.mensagem, f.contato, f.versao, f.lido
  from public.user_feedback f
  left join auth.users u on u.id = f.user_id
  where public.is_movo_admin()
  order by f.lido asc, f.created_at desc
  limit limit_n;
$$;

grant execute on function public.admin_feedback_list(int) to authenticated;

create or replace function public.admin_feedback_lido(p_id bigint, p_lido boolean)
returns void
language sql
security definer
set search_path = public, auth
as $$
  update public.user_feedback set lido = p_lido
  where id = p_id
    and public.is_movo_admin();
$$;

grant execute on function public.admin_feedback_lido(bigint, boolean) to authenticated;

-- limite: 10 por dia por pessoa
create or replace function public.user_feedback_limite()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.user_feedback
      where user_id = new.user_id and created_at > now() - interval '1 day') >= 10 then
    raise exception 'limite_feedback';
  end if;
  return new;
end;
$$;

create trigger user_feedback_limite_trg before insert on public.user_feedback
  for each row execute function public.user_feedback_limite();

-- ======================================================================
-- app_opens_setup.sql
-- ======================================================================
-- Registra cada abertura do app (1 insert por carregamento, ver app.js) pra
-- dar visibilidade real de uso na visão gerencial. "Último login" (do Auth
-- do Supabase) só muda quando a sessão expira e a pessoa precisa logar nela
-- de novo — numa sessão longa isso pode ficar semanas sem acontecer mesmo
-- com uso diário — então sozinho ele não serve pra saber se alguém tá
-- realmente usando o app. app_opens é a fonte de verdade do "último acesso".
--
-- A tabela já existia (criada fora desse repo) com a coluna de data chamada
-- "opened_at" — esse script respeita isso em vez de tentar criar
-- "created_at" por cima, e só cria do zero (com "opened_at" também) se a
-- tabela ainda não existir em algum outro banco/ambiente.

create table if not exists public.app_opens (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  opened_at timestamptz not null default now()
);

create index if not exists app_opens_user_opened_idx on public.app_opens (user_id, opened_at desc);

alter table public.app_opens enable row level security;

grant select, insert on public.app_opens to authenticated;

-- Sem policy de select: ninguém lê os registros de abertura dos outros (nem
-- os próprios, via client) — só a função admin_usage_stats (security
-- definer) consegue agregar isso, e só devolve algo pro e-mail admin.
drop policy if exists app_opens_insert_own on public.app_opens;
create policy app_opens_insert_own on public.app_opens
  for insert with check (auth.uid() = user_id or user_id is null);

-- ======================================================================
-- app_events_setup.sql
-- ======================================================================
-- Eventos de uso do app (só nome + usuário + hora), pra medir adoção de
-- funcionalidades no painel de admin — por enquanto, os ajustes no treino do
-- dia: treino_concluido, treino_concluido_com_ajuste, ficha_salva_com_ajustes.

create table if not exists public.app_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

alter table public.app_events enable row level security;

grant insert on public.app_events to authenticated;

drop policy if exists app_events_insert_own on public.app_events;
create policy app_events_insert_own on public.app_events
  for insert with check (auth.uid() = user_id);

-- Contagem por evento nos últimos N dias (default 30): total de eventos e
-- quantos usuários diferentes. Mesmo esquema de segurança das outras funções
-- admin: security definer + confere o e-mail de quem chamou; pra qualquer
-- outro usuário não devolve nenhuma linha.
drop function if exists public.admin_event_counts(int);

create function public.admin_event_counts(dias int default 30)
returns table (name text, total bigint, usuarios bigint)
language sql
security definer
set search_path = public, auth
as $$
  select e.name, count(*) as total, count(distinct e.user_id) as usuarios
  from public.app_events e
  where e.created_at >= now() - make_interval(days => dias)
    and public.is_movo_admin()
  group by e.name;
$$;

grant execute on function public.admin_event_counts(int) to authenticated;

-- ======================================================================
-- save_sessions_days.sql
-- ======================================================================
-- Grava só os dias de sessão alterados (mescla por dia), sem sobrescrever os outros dias da nuvem.
-- Roda com os direitos de quem chama (RLS vale): cada pessoa só mexe na própria linha.
create or replace function public.save_sessions_days(p_days jsonb)
returns void
language sql
security invoker
set search_path = public
as $$
  insert into public.app_data (user_id, sessions, updated_at)
  values (auth.uid(), p_days, now())
  on conflict (user_id) do update
    set sessions = public.app_data.sessions || excluded.sessions,
        updated_at = now();
$$;

revoke execute on function public.save_sessions_days(jsonb) from public, anon;
grant execute on function public.save_sessions_days(jsonb) to authenticated;

-- ======================================================================
-- avatars_setup.sql
-- ======================================================================
-- Foto de perfil: bucket público "avatars" (leitura aberta pela URL; só o dono grava na própria pasta).
-- Seguro rodar de novo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 524288, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 524288, allowed_mime_types = array['image/jpeg'];

drop policy if exists avatars_select_own on storage.objects;
create policy avatars_select_own on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_insert_own on storage.objects;
create policy avatars_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_update_own on storage.objects;
create policy avatars_update_own on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_delete_own on storage.objects;
create policy avatars_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ======================================================================
-- strava_setup.sql
-- ======================================================================
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

-- ======================================================================
-- strava_grants.sql
-- ======================================================================
grant select, insert, update, delete on public.strava_connections to authenticated;

-- ======================================================================
-- report_shares_setup.sql
-- ======================================================================
-- Compartilhamento de relatórios entre contas do Movo (ex: aluno -> fisio).
-- O aluno escolhe o e-mail de quem pode ver, e quais categorias de dado
-- ficam visíveis. A filtragem por categoria acontece aqui dentro do banco
-- (não é só esconder aba no app) — get_shared_report só devolve o que o
-- aluno liberou, e só pra quem ele liberou.

create table public.report_shares (
  id bigint generated always as identity primary key,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  owner_email text not null,
  viewer_email text not null,
  share_frequencia boolean not null default true,
  share_carga boolean not null default true,
  share_peso_notas boolean not null default false,
  share_treinos boolean not null default false,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (owner_user_id, viewer_email)
);

alter table public.report_shares enable row level security;

grant select, insert, update, delete on public.report_shares to authenticated;

-- O dono (aluno) vê/gerencia livremente os compartilhamentos que ele criou.
create policy report_shares_owner_all on public.report_shares
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

-- Quem recebeu acesso (fisio) só consegue ver a linha em que o e-mail dele
-- bate com viewer_email, e só enquanto não foi revogado.
create policy report_shares_viewer_select on public.report_shares
  for select using (
    revoked_at is null
    and viewer_email = (select email from auth.users where id = auth.uid())
  );

-- Devolve os dados do aluno pro fisio, filtrados pelas categorias que ele
-- liberou. security definer: roda com privilégio elevado, mas só devolve
-- algo se existir um compartilhamento ativo pro e-mail de quem chamou —
-- checado aqui dentro, não só no app.
create or replace function public.get_shared_report(p_owner_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  caller_email text;
  share_row public.report_shares%rowtype;
  ad public.app_data%rowtype;
  found_ad boolean;
  filtered_sessions jsonb := '{}'::jsonb;
  date_key text;
  session_val jsonb;
  log_val jsonb;
  new_log jsonb;
  item_key text;
  item_val jsonb;
  new_item jsonb;
  ex_key text;
  ex_val jsonb;
  new_ex jsonb;
  new_treino_log jsonb;
  min_treinos jsonb;
begin
  select email into caller_email from auth.users where id = auth.uid();
  if caller_email is null then
    raise exception 'not_authenticated';
  end if;

  select * into share_row from public.report_shares
    where owner_user_id = p_owner_user_id
      and viewer_email = caller_email
      and revoked_at is null
    limit 1;
  if not found then
    raise exception 'not_shared';
  end if;

  select * into ad from public.app_data where user_id = p_owner_user_id;
  found_ad := found;
  if not found_ad then
    ad.sessions := '{}'::jsonb;
    ad.treinos := '[]'::jsonb;
    ad.atividades := '[]'::jsonb;
  end if;

  if share_row.share_treinos then
    min_treinos := coalesce(ad.treinos, '[]'::jsonb);
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', t->>'id',
      'nome', t->>'nome',
      'blocos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'nome', b->>'nome',
          'exercicios', (
            select coalesce(jsonb_agg(jsonb_build_object('id', ex->>'id', 'nome', ex->>'nome')), '[]'::jsonb)
            from jsonb_array_elements(coalesce(b->'exercicios', '[]'::jsonb)) ex
          )
        )), '[]'::jsonb)
        from jsonb_array_elements(coalesce(t->'blocos', '[]'::jsonb)) b
      )
    )), '[]'::jsonb)
    into min_treinos
    from jsonb_array_elements(coalesce(ad.treinos, '[]'::jsonb)) t;
  end if;

  for date_key, session_val in select * from jsonb_each(coalesce(ad.sessions, '{}'::jsonb))
  loop
    new_log := '{}'::jsonb;
    if share_row.share_frequencia then
      log_val := coalesce(session_val->'log', '{}'::jsonb);
      for item_key, item_val in select * from jsonb_each(log_val)
      loop
        if item_key like 'treino:%' then
          new_treino_log := '{}'::jsonb;
          for ex_key, ex_val in select * from jsonb_each(item_val)
          loop
            new_ex := jsonb_build_object('status', ex_val->'status');
            if share_row.share_peso_notas then
              new_ex := new_ex || jsonb_build_object('sets', coalesce(ex_val->'sets', '[]'::jsonb));
              if ex_val ? 'comentario' then
                new_ex := new_ex || jsonb_build_object('comentario', ex_val->'comentario');
              end if;
            end if;
            new_treino_log := new_treino_log || jsonb_build_object(ex_key, new_ex);
          end loop;
          new_log := new_log || jsonb_build_object(item_key, new_treino_log);
        else
          new_item := jsonb_build_object('status', item_val->'status');
          if share_row.share_peso_notas and item_val ? 'comentario' then
            new_item := new_item || jsonb_build_object('comentario', item_val->'comentario');
          end if;
          new_log := new_log || jsonb_build_object(item_key, new_item);
        end if;
      end loop;
    end if;

    filtered_sessions := filtered_sessions || jsonb_build_object(
      date_key,
      jsonb_build_object(
        'log', new_log,
        'cargas', case when share_row.share_carga then coalesce(session_val->'cargas', '{}'::jsonb) else '{}'::jsonb end,
        'extras', case when share_row.share_frequencia then coalesce(session_val->'extras', '[]'::jsonb) else '[]'::jsonb end
      )
    );
  end loop;

  return jsonb_build_object(
    'owner_email', share_row.owner_email,
    'sessions', filtered_sessions,
    'treinos', min_treinos,
    'atividades', coalesce(ad.atividades, '[]'::jsonb),
    'flags', jsonb_build_object(
      'frequencia', share_row.share_frequencia,
      'carga', share_row.share_carga,
      'peso_notas', share_row.share_peso_notas,
      'treinos', share_row.share_treinos
    )
  );
end;
$$;

grant execute on function public.get_shared_report(uuid) to authenticated;

-- ======================================================================
-- report_shares_names.sql
-- ======================================================================
-- Nome de quem compartilhou relatório comigo (usado na tela "Compartilhados comigo").
-- Requer base_app_e_amigos.sql e report_shares_setup.sql. Seguro rodar de novo.
create or replace function public.get_share_owner_names()
returns table(owner_user_id uuid, nome text)
language sql
security definer
set search_path to 'public', 'auth'
as $$
  select rs.owner_user_id, coalesce(ad.display_name, rs.owner_email)
  from public.report_shares rs
  left join public.app_data ad on ad.user_id = rs.owner_user_id
  where rs.viewer_email = auth.email() and rs.revoked_at is null;
$$;
revoke all on function public.get_share_owner_names() from public, anon;
grant execute on function public.get_share_owner_names() to authenticated;

-- ======================================================================
-- races_cloud_setup.sql
-- ======================================================================
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

-- ======================================================================
-- race_favorites.sql
-- ======================================================================
-- Provas favoritas (⭐): guardadas para decidir depois, separadas de "Vou nessa" (race_entries).
-- Cada pessoa só enxerga e mexe nas próprias linhas. Não aparece para amigos. Seguro rodar de novo.
create table if not exists public.race_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  race_id text not null check (char_length(race_id) between 1 and 200),
  created_at timestamptz not null default now(),
  primary key (user_id, race_id)
);

alter table public.race_favorites enable row level security;
grant select, insert, update, delete on public.race_favorites to authenticated;

drop policy if exists race_favorites_own on public.race_favorites;
create policy race_favorites_own on public.race_favorites for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ======================================================================
-- challenges_setup.sql
-- ======================================================================
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

-- ======================================================================
-- challenge_timeline.sql
-- ======================================================================
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

-- ======================================================================
-- plan_generations_setup.sql
-- ======================================================================
-- Controle de uso da geração de plano de corrida com IA (limite por pessoa por mês).
-- Cada geração reservada conta 1; se a chamada à IA falhar, a função devolve (apaga) a reserva.
-- O limite padrão é 3 por mês (mês do horário de São Paulo) e pode ser mudado nos parâmetros.
-- Seguro rodar de novo.

create table if not exists public.plan_generations (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  prova text check (prova is null or char_length(prova) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists plan_generations_user_created_idx on public.plan_generations (user_id, created_at desc);

alter table public.plan_generations enable row level security;
grant select on public.plan_generations to authenticated;

drop policy if exists plan_generations_select_own on public.plan_generations;
create policy plan_generations_select_own on public.plan_generations
  for select to authenticated using (auth.uid() = user_id);

-- Quantos planos a pessoa já gerou neste mês.
create or replace function public.plan_generation_usage(max_per_month int default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select count(*) into usados from public.plan_generations where user_id = uid and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month);
end;
$$;

-- Reserva uma geração (atômico). Devolve ok=false quando o limite do mês já foi usado.
create or replace function public.reserve_plan_generation(p_prova text default null, max_per_month int default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova) values (uid, left(p_prova, 120)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- Devolve a reserva quando a IA falhou (só apaga linha da própria pessoa).
create or replace function public.refund_plan_generation(p_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.plan_generations where id = p_id and user_id = auth.uid();
$$;

revoke all on function public.plan_generation_usage(int) from public, anon;
revoke all on function public.reserve_plan_generation(text, int) from public, anon;
revoke all on function public.refund_plan_generation(bigint) from public, anon;
grant execute on function public.plan_generation_usage(int) to authenticated;
grant execute on function public.reserve_plan_generation(text, int) to authenticated;
grant execute on function public.refund_plan_generation(bigint) to authenticated;

-- ======================================================================
-- plan_limit_admin.sql
-- ======================================================================
-- Sem limite mensal de planos com IA para o administrador (ardurso@gmail.com), para testes.
-- Seguro rodar de novo. Requer plan_generations_setup.sql.

create or replace function public.plan_generation_usage(max_per_month int default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  select count(*) into usados from public.plan_generations where user_id = uid and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month);
end;
$$;

create or replace function public.reserve_plan_generation(p_prova text default null, max_per_month int default 3)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova) values (uid, left(p_prova, 120)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- ======================================================================
-- ai_quota_kinds.sql
-- ======================================================================
-- Cota mensal de IA por tipo ('plano_corrida', 'historico', ...). Seguro rodar de novo.
-- Requer plan_generations_setup.sql. Substitui as funções de cota (já inclui o "sem limite" do admin).

alter table public.plan_generations add column if not exists kind text not null default 'plano_corrida';

create or replace function public.ai_generation_usage(p_kind text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month);
end;
$$;

create or replace function public.reserve_ai_generation(p_kind text, p_label text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

create or replace function public.plan_generation_usage(max_per_month int default 3)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.ai_generation_usage('plano_corrida', max_per_month);
$$;

create or replace function public.reserve_plan_generation(p_prova text default null, max_per_month int default 3)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.reserve_ai_generation('plano_corrida', p_prova, max_per_month);
$$;

revoke all on function public.ai_generation_usage(text, int) from public, anon;
revoke all on function public.reserve_ai_generation(text, text, int) from public, anon;
grant execute on function public.ai_generation_usage(text, int) to authenticated;
grant execute on function public.reserve_ai_generation(text, text, int) to authenticated;

-- ======================================================================
-- ai_usage_cost.sql
-- ======================================================================
-- Custo da IA: registra tokens e US$ de cada chamada (inclusive as que falham) e mostra o total no painel admin.
-- Seguro rodar de novo. Requer plan_generations_setup.sql (não depende de dados antigos).

create table if not exists public.ai_usage_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  modelo text,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  custo_usd numeric(12,6) not null default 0,
  ok boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists ai_usage_log_created_idx on public.ai_usage_log (created_at desc);
alter table public.ai_usage_log enable row level security;
-- sem policies: ninguém lê/escreve direto; só as funções abaixo.

create or replace function public.log_ai_usage(p_kind text, p_modelo text, p_in int, p_out int, p_custo numeric, p_ok boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into public.ai_usage_log (user_id, kind, modelo, input_tokens, output_tokens, custo_usd, ok)
  values (auth.uid(), left(p_kind, 40), left(p_modelo, 60), greatest(0, coalesce(p_in, 0)), greatest(0, coalesce(p_out, 0)), greatest(0, coalesce(p_custo, 0)), coalesce(p_ok, true));
end;
$$;
revoke all on function public.log_ai_usage(text, text, int, int, numeric, boolean) from public, anon;
grant execute on function public.log_ai_usage(text, text, int, int, numeric, boolean) to authenticated;

drop function if exists public.admin_ai_cost();
create function public.admin_ai_cost()
returns table (total_usd numeric, mes_usd numeric, chamadas bigint, chamadas_mes bigint, falhas bigint, tokens_in bigint, tokens_out bigint, desde timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select coalesce(sum(l.custo_usd), 0),
         coalesce(sum(l.custo_usd) filter (where l.created_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'), 0),
         count(*),
         count(*) filter (where l.created_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'),
         count(*) filter (where not l.ok),
         coalesce(sum(l.input_tokens), 0)::bigint,
         coalesce(sum(l.output_tokens), 0)::bigint,
         min(l.created_at)
  from public.ai_usage_log l
  where public.is_movo_admin();
$$;
revoke all on function public.admin_ai_cost() from public, anon;
grant execute on function public.admin_ai_cost() to authenticated;

-- ======================================================================
-- ai_kill_switch.sql
-- ======================================================================
-- Teto diário de gasto com IA + interruptor geral (admin). Seguro rodar de novo.
-- Requer ai_quota_kinds.sql e ai_usage_cost.sql.

create table if not exists public.app_config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.app_config enable row level security;
-- sem policies: só as funções abaixo (security definer) leem/escrevem.

insert into public.app_config (chave, valor) values
  ('ai_ativa', 'true'::jsonb),
  ('ai_teto_diario_usd', '5'::jsonb)
on conflict (chave) do nothing;

-- Devolve null se a IA pode ser usada agora, ou o motivo: 'desligada' | 'teto_diario'.
create or replace function public.ai_bloqueio()
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  ativa boolean := coalesce((select (valor)::text::boolean from public.app_config where chave = 'ai_ativa'), true);
  teto numeric := coalesce((select (valor)::text::numeric from public.app_config where chave = 'ai_teto_diario_usd'), 5);
  hoje numeric;
begin
  if not ativa then return 'desligada'; end if;
  if teto > 0 then
    select coalesce(sum(custo_usd), 0) into hoje from public.ai_usage_log
     where created_at >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
    if hoje >= teto and not public.is_movo_admin() then
      return 'teto_diario';
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.ai_bloqueio() from public, anon;
grant execute on function public.ai_bloqueio() to authenticated;

-- Reserva de cota: agora recusa quando a IA está bloqueada.
create or replace function public.reserve_ai_generation(p_kind text, p_label text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
  bloqueio text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  bloqueio := public.ai_bloqueio();
  if bloqueio is not null then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', bloqueio, 'usados', 0, 'limite', max_per_month,
      'mensagem', case bloqueio when 'desligada' then 'A IA está temporariamente desligada. Tente mais tarde.' else 'A IA atingiu o limite de uso de hoje. Tente amanhã.' end);
  end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- Painel do admin: estado atual e gasto de hoje.
create or replace function public.admin_ai_controle()
returns jsonb
language sql
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'ativa', coalesce((select (valor)::text::boolean from public.app_config where chave = 'ai_ativa'), true),
    'teto_usd', coalesce((select (valor)::text::numeric from public.app_config where chave = 'ai_teto_diario_usd'), 5),
    'hoje_usd', coalesce((select sum(custo_usd) from public.ai_usage_log
        where created_at >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'), 0)
  )
  where public.is_movo_admin();
$$;

create or replace function public.admin_ai_definir(p_ativa boolean, p_teto numeric)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('ai_ativa', to_jsonb(coalesce(p_ativa, true)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  if p_teto is not null and p_teto >= 0 then
    insert into public.app_config (chave, valor, atualizado_em) values ('ai_teto_diario_usd', to_jsonb(p_teto), now())
      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
end;
$$;

revoke all on function public.admin_ai_controle() from public, anon;
revoke all on function public.admin_ai_definir(boolean, numeric) from public, anon;
grant execute on function public.admin_ai_controle() to authenticated;
grant execute on function public.admin_ai_definir(boolean, numeric) to authenticated;

-- ======================================================================
-- ai_jobs_setup.sql
-- ======================================================================
-- Geração com IA em segundo plano: o app pede, a função grava o resultado aqui e o app consulta.
-- Assim a pessoa pode sair da tela (ou do app) e o plano continua sendo gerado.
-- Seguro rodar de novo. Requer plan_generations_setup.sql.

create table if not exists public.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  label text,
  status text not null default 'rodando' check (status in ('rodando', 'pronto', 'erro')),
  result jsonb,
  reserva_id bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ai_jobs_user_created_idx on public.ai_jobs (user_id, created_at desc);

alter table public.ai_jobs enable row level security;
grant select on public.ai_jobs to authenticated;
drop policy if exists ai_jobs_select_own on public.ai_jobs;
create policy ai_jobs_select_own on public.ai_jobs for select to authenticated using (auth.uid() = user_id);

-- Tarefas que ficaram "rodando" por mais de 6 minutos (função morreu): marca erro e devolve a reserva do limite.
create or replace function public.expire_stale_ai_jobs()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  with ex as (
    update public.ai_jobs
       set status = 'erro', updated_at = now(),
           result = jsonb_build_object('ok', false, 'erro', 'expirou', 'mensagem', 'A geração demorou demais e foi cancelada. Tente de novo (esta tentativa não conta no limite).')
     where user_id = uid and status = 'rodando' and created_at < now() - interval '6 minutes'
     returning reserva_id
  )
  delete from public.plan_generations where user_id = uid and id in (select reserva_id from ex where reserva_id is not null);
end;
$$;
revoke all on function public.expire_stale_ai_jobs() from public, anon;
grant execute on function public.expire_stale_ai_jobs() to authenticated;

-- Cria a tarefa. Só uma por tipo rodando ao mesmo tempo.
create or replace function public.create_ai_job(p_kind text, p_label text, p_reserva bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  existente uuid;
  novo uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  perform public.expire_stale_ai_jobs();
  select id into existente from public.ai_jobs where user_id = uid and kind = p_kind and status = 'rodando' order by created_at desc limit 1;
  if existente is not null then
    return jsonb_build_object('ok', false, 'erro', 'em_andamento', 'id', existente);
  end if;
  insert into public.ai_jobs (user_id, kind, label, reserva_id) values (uid, left(p_kind, 40), left(p_label, 120), p_reserva) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo);
end;
$$;
revoke all on function public.create_ai_job(text, text, bigint) from public, anon;
grant execute on function public.create_ai_job(text, text, bigint) to authenticated;

-- Grava o resultado final da tarefa.
create or replace function public.finish_ai_job(p_id uuid, p_status text, p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.ai_jobs
     set status = case when p_status = 'pronto' then 'pronto' else 'erro' end, result = p_result, updated_at = now()
   where id = p_id and user_id = auth.uid() and status = 'rodando';
end;
$$;
revoke all on function public.finish_ai_job(uuid, text, jsonb) from public, anon;
grant execute on function public.finish_ai_job(uuid, text, jsonb) to authenticated;

-- ======================================================================
-- app_config_dominio.sql
-- ======================================================================
-- Aviso de mudança de endereço do app (banner "Estamos mudando para ..."). Lido pelo app via app_dominio_novo().
-- Para ligar: update public.app_config set valor = jsonb_set(valor, '{ativo}', 'true') where chave = 'dominio_novo';
-- Requer ai_kill_switch.sql (cria public.app_config). Seguro rodar de novo; não sobrescreve o valor existente.
insert into public.app_config (chave, valor)
values ('dominio_novo', '{"url": "https://app.movoapp.com.br", "ativo": false, "redirecionar": false}'::jsonb)
on conflict (chave) do nothing;

create or replace function public.app_dominio_novo()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select valor from public.app_config where chave = 'dominio_novo'), '{"ativo": false}'::jsonb)
$$;
grant execute on function public.app_dominio_novo() to anon, authenticated;

-- ======================================================================
-- feature_flags.sql
-- ======================================================================
-- Experimentos por usuário (feature flags com lista de liberados).
-- Hoje: 'ajuste_semana' (Ajustar minha semana / "Sua semana mudou" com IA), 'blocos' (editor de sessão em blocos,
-- liberado para todos desde 20/10) e 'plano' (plano de semanas, fase 2; v207).
-- feature_allowed é a mesma aqui e em feature_flags_todos.sql (qualquer ordem de execução dá o mesmo resultado).
-- Regra: só quem o admin liberar usa, e quem tem Strava conectado fica de fora (a política da API do Strava
-- proíbe usar dados do Strava em IA). O admin (ardurso@gmail.com) sempre tem acesso, para testar.
-- Rodar uma vez no SQL editor do Supabase. Pode rodar de novo sem problema.

create table if not exists public.feature_access (
  user_id uuid not null references auth.users(id) on delete cascade,
  feature text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, feature)
);
alter table public.feature_access enable row level security;  -- sem policies: só as funções abaixo mexem

-- Interna: decide se um usuário pode usar a feature.
create or replace function public.feature_allowed(p_uid uuid, p_feature text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when p_uid is null then false
    when public.movo_admin_uid(p_uid) then true
    when p_feature = 'blocos' then true  -- liberado para todos em 20/10 (decisão do Andre)
    when p_feature = 'ajuste_semana' then
      (coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_ajuste_semana_todos'), false)
       or exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature))
      and not exists (select 1 from public.strava_connections where user_id = p_uid)
    else coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_' || p_feature || '_todos'), false)
      or exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature)
  end;
$$;
revoke all on function public.feature_allowed(uuid, text) from public, anon, authenticated;

-- O app pergunta quais experimentos estão liberados pra pessoa logada.
create or replace function public.my_features()
returns text[]
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(array_agg(f), '{}'::text[])
  from unnest(array['ajuste_semana', 'blocos', 'plano']) as f
  where public.feature_allowed(auth.uid(), f);
$$;
revoke all on function public.my_features() from public, anon;
grant execute on function public.my_features() to authenticated;

-- Admin: lista quem está liberado (e se o Strava bloqueia).
create or replace function public.admin_feature_list(p_feature text)
returns table (email text, liberado_em timestamptz, tem_strava boolean)
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.email::text, fa.created_at,
         exists (select 1 from public.strava_connections s where s.user_id = fa.user_id)
  from public.feature_access fa
  join auth.users u on u.id = fa.user_id
  where fa.feature = p_feature
    and public.is_movo_admin()
  order by fa.created_at desc;
$$;

-- Admin: libera ou remove uma pessoa pelo e-mail.
create or replace function public.admin_feature_set(p_email text, p_feature text, p_on boolean)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  alvo uuid;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select id into alvo from auth.users where lower(email) = lower(trim(p_email));
  if alvo is null then return 'usuario_nao_encontrado'; end if;
  if p_on then
    insert into public.feature_access (user_id, feature) values (alvo, p_feature) on conflict do nothing;
  else
    delete from public.feature_access where user_id = alvo and feature = p_feature;
  end if;
  return 'ok';
end;
$$;
revoke all on function public.admin_feature_list(text) from public, anon;
revoke all on function public.admin_feature_set(text, text, boolean) from public, anon;
grant execute on function public.admin_feature_list(text) to authenticated;
grant execute on function public.admin_feature_set(text, text, boolean) to authenticated;

-- Trava no servidor: reservar uma geração de 'ajuste_semana' só funciona pra quem está liberado.
create or replace function public.reserve_ai_generation(p_kind text, p_label text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
  bloqueio text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  bloqueio := public.ai_bloqueio();
  if bloqueio is not null then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', bloqueio, 'usados', 0, 'limite', max_per_month,
      'mensagem', case bloqueio when 'desligada' then 'A IA está temporariamente desligada. Tente mais tarde.' else 'A IA atingiu o limite de uso de hoje. Tente amanhã.' end);
  end if;
  if p_kind = 'ajuste_semana' and not public.feature_allowed(uid, 'ajuste_semana') then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', 'sem_acesso', 'usados', 0, 'limite', max_per_month,
      'mensagem', 'O ajuste da semana com IA está em teste fechado e ainda não está liberado pra você.');
  end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- ======================================================================
-- feature_flags_todos.sql
-- ======================================================================
-- Experimento "Ajustar minha semana": liberado pra TODOS por padrão (quem tem Strava conectado continua de fora).
-- O admin pode desligar o "pra todos" no app (Configurações > Admin) e voltar a liberar só por e-mail.
-- Rodar depois de feature_flags.sql. Pode rodar de novo sem problema.

-- Padrão atual: ligado pra todos.
insert into public.app_config (chave, valor, atualizado_em)
values ('ff_ajuste_semana_todos', 'true'::jsonb, now())
on conflict (chave) do nothing;

create or replace function public.feature_allowed(p_uid uuid, p_feature text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when p_uid is null then false
    when public.movo_admin_uid(p_uid) then true
    when p_feature = 'blocos' then true  -- liberado para todos em 20/10 (decisão do Andre)
    when p_feature = 'ajuste_semana' then
      (coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_ajuste_semana_todos'), false)
       or exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature))
      and not exists (select 1 from public.strava_connections where user_id = p_uid)
    else coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_' || p_feature || '_todos'), false)
      or exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature)
  end;
$$;
revoke all on function public.feature_allowed(uuid, text) from public, anon, authenticated;

-- Admin: lê e muda o "pra todos".
create or replace function public.admin_feature_todos(p_feature text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_' || p_feature || '_todos'), false)
  where public.is_movo_admin();
$$;

create or replace function public.admin_feature_todos_set(p_feature text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if p_feature is null or p_feature not in ('ajuste_semana', 'plano') then raise exception 'feature desconhecida'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('ff_' || p_feature || '_todos', to_jsonb(coalesce(p_on, false)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end;
$$;
revoke all on function public.admin_feature_todos(text) from public, anon;
revoke all on function public.admin_feature_todos_set(text, boolean) from public, anon;
grant execute on function public.admin_feature_todos(text) to authenticated;
grant execute on function public.admin_feature_todos_set(text, boolean) to authenticated;

-- ======================================================================
-- coach_setup.sql
-- ======================================================================
-- Modo treinador do Movo: vínculo treinador↔aluno, envio de semanas, comentários e funil.
-- Seguro rodar de novo (idempotente). Veja docs/PLANO_TREINADORES.md.
--
-- Regras de segurança:
--  * O treinador NUNCA lê app_data direto: só pelas funções coach_* (security definer),
--    que checam vínculo ativo e a permissão que o aluno liberou.
--  * Permissão desligada devolve "bloqueado" (não zero), e esforço/dor vêm desligados por padrão.
--  * Ninguém escreve direto nas tabelas: só pelas funções.

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------
create table if not exists public.coach_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nome_exibicao text not null default 'Treinador',
  liberado boolean not null default false, -- liberado manualmente (veja o fim do arquivo)
  created_at timestamptz not null default now()
);

create table if not exists public.coach_links (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid references auth.users(id) on delete cascade,
  student_label text,
  status text not null default 'pendente'
    check (status in ('pendente', 'ativo', 'pausado', 'encerrado', 'recusado')),
  invite_code text not null unique,
  permissions jsonb not null default '{"ver_treinos":true,"ver_cargas":true,"ver_esforco_dor":false,"ver_corrida":true}'::jsonb,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  ended_at timestamptz,
  ended_by uuid,
  check (student_id is null or student_id <> coach_id)
);
-- 1 treinador ativo (ou pausado) por aluno.
create unique index if not exists coach_links_one_active_per_student
  on public.coach_links (student_id) where status in ('ativo', 'pausado');
create index if not exists coach_links_coach_idx on public.coach_links (coach_id, status);
create index if not exists coach_links_student_idx on public.coach_links (student_id, status);

create table if not exists public.coach_assignments (
  id uuid primary key default gen_random_uuid(),
  link_id uuid not null references public.coach_links(id) on delete cascade,
  tipo text not null default 'semana' check (tipo in ('semana', 'ficha', 'corrida')),
  versao int not null default 1,
  payload jsonb not null,
  mensagem text check (mensagem is null or char_length(mensagem) <= 500),
  status text not null default 'enviado'
    check (status in ('enviado', 'visto', 'aceito', 'recusado', 'aplicado')),
  motivo_recusa text check (motivo_recusa is null or char_length(motivo_recusa) <= 200),
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  decided_at timestamptz
);
create index if not exists coach_assignments_link_idx on public.coach_assignments (link_id, created_at desc);

create table if not exists public.coach_notes (
  id uuid primary key default gen_random_uuid(),
  link_id uuid not null references public.coach_links(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  session_ref text,
  texto text not null check (char_length(texto) between 1 and 500),
  lida boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists coach_notes_link_idx on public.coach_notes (link_id, date desc);

create table if not exists public.coach_templates (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 80),
  payload jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists coach_templates_coach_idx on public.coach_templates (coach_id);

create table if not exists public.coach_audit (
  id bigint generated always as identity primary key,
  link_id uuid references public.coach_links(id) on delete cascade,
  ator uuid,
  acao text not null,
  meta jsonb,
  quando timestamptz not null default now()
);
create index if not exists coach_audit_link_idx on public.coach_audit (link_id, quando desc);

create table if not exists public.coach_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  evento text not null check (char_length(evento) <= 60),
  meta jsonb,
  quando timestamptz not null default now()
);
create index if not exists coach_events_user_idx on public.coach_events (user_id, quando desc);

-- ---------------------------------------------------------------------------
-- RLS: leitura restrita às partes; nenhuma escrita direta.
-- ---------------------------------------------------------------------------
alter table public.coach_profiles enable row level security;
alter table public.coach_links enable row level security;
alter table public.coach_assignments enable row level security;
alter table public.coach_notes enable row level security;
alter table public.coach_templates enable row level security;
alter table public.coach_audit enable row level security;
alter table public.coach_events enable row level security;

create or replace function public.coach_is_party(p_link uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.coach_links l
    where l.id = p_link and (l.coach_id = auth.uid() or l.student_id = auth.uid())
  );
$$;

drop policy if exists coach_profiles_select on public.coach_profiles;
create policy coach_profiles_select on public.coach_profiles
  for select to authenticated using (user_id = auth.uid());

drop policy if exists coach_links_select on public.coach_links;
create policy coach_links_select on public.coach_links
  for select to authenticated using (coach_id = auth.uid() or student_id = auth.uid());

-- O treinador mantém o que ele mesmo enviou, mesmo após encerrar; o aluno vê o que recebeu.
drop policy if exists coach_assignments_select on public.coach_assignments;
create policy coach_assignments_select on public.coach_assignments
  for select to authenticated using (public.coach_is_party(link_id));

-- Notas: depois de encerrado o vínculo, cada um só enxerga as próprias.
drop policy if exists coach_notes_select on public.coach_notes;
create policy coach_notes_select on public.coach_notes
  for select to authenticated using (
    public.coach_is_party(link_id)
    and (
      author_id = auth.uid()
      or exists (select 1 from public.coach_links l where l.id = link_id and l.status in ('ativo', 'pausado'))
    )
  );

drop policy if exists coach_templates_all on public.coach_templates;
create policy coach_templates_all on public.coach_templates
  for all to authenticated using (coach_id = auth.uid()) with check (coach_id = auth.uid());

-- coach_audit e coach_events: sem política = ninguém lê direto (só as funções gravam).

-- ---------------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------------
create or replace function public.coach_hoje()
returns date language sql stable as $$
  select (now() at time zone 'America/Sao_Paulo')::date;
$$;

-- Dia com treino registrado? (qualquer log de exercício ou carga)
create or replace function public.coach_day_done(j jsonb)
returns boolean language sql immutable as $$
  select coalesce(
    (jsonb_typeof(j->'log') = 'object' and (j->'log') <> '{}'::jsonb)
    or (jsonb_typeof(j->'cargas') = 'object' and (j->'cargas') <> '{}'::jsonb),
    false);
$$;

create or replace function public.coach_date(v text)
returns date language sql immutable as $$
  select case when v ~ '^\d{4}-\d{2}-\d{2}$' then v::date end;
$$;

create or replace function public.coach_num(v text)
returns numeric language sql immutable as $$
  select case when v ~ '^[0-9]+(\.[0-9]+)?$' then v::numeric end;
$$;

create or replace function public.coach_clean_perms(p jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ver_treinos', coalesce((p->>'ver_treinos')::boolean, true),
    'ver_cargas', coalesce((p->>'ver_cargas')::boolean, true),
    'ver_esforco_dor', coalesce((p->>'ver_esforco_dor')::boolean, false),
    'ver_corrida', coalesce((p->>'ver_corrida')::boolean, true)
  );
$$;

create or replace function public.coach_assert_coach()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.coach_profiles where user_id = auth.uid() and liberado) then
    raise exception 'treinador não liberado';
  end if;
end;
$$;

create or replace function public.coach_log_event(p_evento text, p_meta jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.coach_events (user_id, evento, meta) values (auth.uid(), left(p_evento, 60), p_meta);
end;
$$;

-- ---------------------------------------------------------------------------
-- Perfil do treinador
-- ---------------------------------------------------------------------------
create or replace function public.coach_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.coach_profiles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v from public.coach_profiles where user_id = auth.uid();
  if not found then return null; end if;
  return jsonb_build_object('liberado', v.liberado, 'nome_exibicao', v.nome_exibicao);
end;
$$;

create or replace function public.coach_set_name(p_nome text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome obrigatório'; end if;
  update public.coach_profiles set nome_exibicao = left(trim(p_nome), 60) where user_id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- Convite
-- ---------------------------------------------------------------------------
create or replace function public.coach_create_invite(p_label text default null)
returns public.coach_links
language plpgsql security definer set search_path = public as $$
declare
  v_code text; v_row public.coach_links; v_try int := 0;
begin
  perform public.coach_assert_coach();
  if (select count(*) from public.coach_links
      where coach_id = auth.uid() and status in ('pendente', 'ativo', 'pausado')) >= 15 then
    raise exception 'limite de 15 alunos no piloto';
  end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_links (coach_id, student_label, invite_code)
  values (auth.uid(), nullif(left(trim(coalesce(p_label, '')), 60), ''), v_code)
  returning * into v_row;
  insert into public.coach_audit (link_id, ator, acao) values (v_row.id, auth.uid(), 'convite_criado');
  perform public.coach_log_event('convite_criado');
  return v_row;
end;
$$;

-- Gera um código novo para um convite pendente/expirado (reenviar).
create or replace function public.coach_resend_invite(p_link uuid)
returns public.coach_links
language plpgsql security definer set search_path = public as $$
declare v_code text; v_row public.coach_links; v_try int := 0;
begin
  perform public.coach_assert_coach();
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  update public.coach_links set invite_code = v_code, created_at = now()
   where id = p_link and coach_id = auth.uid() and status = 'pendente'
  returning * into v_row;
  if not found then raise exception 'convite não encontrado'; end if;
  return v_row;
end;
$$;

-- Prévia para o aluno (antes de aceitar).
create or replace function public.coach_invite_preview(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; n text; v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where invite_code = upper(trim(p_code));
  if not found then return null; end if;
  select nome_exibicao into n from public.coach_profiles where user_id = l.coach_id;
  v_status := case
    when l.status = 'pendente' and l.created_at < now() - interval '14 days' then 'expirado'
    else l.status end;
  perform public.coach_log_event('convite_aberto');
  return jsonb_build_object(
    'link_id', l.id,
    'coach_nome', coalesce(n, 'Treinador'),
    'status', v_status,
    'eh_o_proprio', l.coach_id = auth.uid(),
    'ja_tem_treinador', exists (
      select 1 from public.coach_links x
      where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')),
    'treinador_atual', (
      select p.nome_exibicao from public.coach_links x
      join public.coach_profiles p on p.user_id = x.coach_id
      where x.student_id = auth.uid() and x.status in ('ativo', 'pausado') limit 1)
  );
end;
$$;

create or replace function public.coach_accept_invite(p_code text, p_permissions jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; v_perms jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where invite_code = upper(trim(p_code)) for update;
  if not found then raise exception 'convite inválido'; end if;
  if l.coach_id = auth.uid() then raise exception 'você não pode ser aluno de si mesmo'; end if;
  if l.status <> 'pendente' then raise exception 'convite não está mais disponível'; end if;
  if l.created_at < now() - interval '14 days' then raise exception 'convite expirado'; end if;
  if exists (select 1 from public.coach_links x
             where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')) then
    raise exception 'ja_tem_treinador';
  end if;
  v_perms := public.coach_clean_perms(coalesce(p_permissions, '{}'::jsonb));
  update public.coach_links
     set student_id = auth.uid(), status = 'ativo', permissions = v_perms, accepted_at = now()
   where id = l.id;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (l.id, auth.uid(), 'consentimento', jsonb_build_object('texto_versao', 'v1', 'permissions', v_perms, 'maior_de_18', true));
  perform public.coach_log_event('convite_aceito');
  return jsonb_build_object('link_id', l.id, 'permissions', v_perms);
end;
$$;

create or replace function public.coach_decline_invite(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_links set status = 'recusado', ended_at = now(), ended_by = auth.uid()
   where invite_code = upper(trim(p_code)) and status = 'pendente' and coach_id <> auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- Vínculo: permissões, pausa, encerramento
-- ---------------------------------------------------------------------------
create or replace function public.coach_update_permissions(p_link uuid, p_perms jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v := public.coach_clean_perms(p_perms);
  update public.coach_links set permissions = v
   where id = p_link and student_id = auth.uid() and status in ('ativo', 'pausado');
  if not found then raise exception 'vínculo não encontrado'; end if;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (p_link, auth.uid(), 'permissoes', jsonb_build_object('texto_versao', 'v1', 'permissions', v));
  return v;
end;
$$;

-- Aluno: 'ativo' | 'pausado' | 'encerrado'. Treinador: só 'encerrado' (e cancelar convite pendente).
create or replace function public.coach_set_status(p_link uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare l public.coach_links;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where id = p_link for update;
  if not found or (l.coach_id <> auth.uid() and l.student_id is distinct from auth.uid()) then
    raise exception 'vínculo não encontrado';
  end if;
  if p_status = 'encerrado' then
    if l.status in ('encerrado', 'recusado') then return; end if;
    update public.coach_links set status = 'encerrado', ended_at = now(), ended_by = auth.uid() where id = p_link;
  elsif p_status in ('ativo', 'pausado') and l.student_id = auth.uid() and l.status in ('ativo', 'pausado') then
    update public.coach_links set status = p_status where id = p_link;
  else
    raise exception 'operação não permitida';
  end if;
  insert into public.coach_audit (link_id, ator, acao) values (p_link, auth.uid(), 'status_' || p_status);
end;
$$;

-- Aluno: seus treinadores (ativo/pausado) e convites que ele aceitou.
create or replace function public.coach_my_coach()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'link_id', l.id, 'status', l.status, 'permissions', l.permissions,
      'coach_nome', coalesce(p.nome_exibicao, 'Treinador'), 'accepted_at', l.accepted_at
    ) order by l.accepted_at desc)
    from public.coach_links l
    left join public.coach_profiles p on p.user_id = l.coach_id
    where l.student_id = auth.uid() and l.status in ('ativo', 'pausado')
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Treinador: lista de alunos
-- ---------------------------------------------------------------------------
create or replace function public.coach_list_students()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; out jsonb := '[]'::jsonb; item jsonb;
  sess jsonb; dias boolean[]; d int; dia date; v_hoje date := public.coach_hoje();
  v_ultimo date; v_semana int; v_dor numeric; v_nome text; v_ass record; perms jsonb;
begin
  perform public.coach_assert_coach();
  perform public.coach_log_event('painel_aberto');
  for r in
    select l.*, a.display_name, a.sessions
    from public.coach_links l
    left join public.app_data a on a.user_id = l.student_id
    where l.coach_id = auth.uid() and l.status in ('pendente', 'ativo', 'pausado')
    order by l.created_at desc
  loop
    v_nome := coalesce(nullif(r.display_name, ''), r.student_label, 'Aluno');
    perms := r.permissions;
    item := jsonb_build_object(
      'link_id', r.id, 'status', r.status, 'nome', v_nome, 'invite_code', r.invite_code,
      'expirado', (r.status = 'pendente' and r.created_at < now() - interval '14 days'),
      'criado_em', r.created_at, 'permissions', perms);
    if r.status = 'ativo' then
      if coalesce((perms->>'ver_treinos')::boolean, false) then
        sess := coalesce(r.sessions, '{}'::jsonb);
        dias := array[]::boolean[];
        v_semana := 0; v_ultimo := null; v_dor := null;
        for d in reverse 6..0 loop
          dia := v_hoje - d;
          dias := dias || public.coach_day_done(sess -> to_char(dia, 'YYYY-MM-DD'));
        end loop;
        select max(public.coach_date(k)) into v_ultimo
          from jsonb_object_keys(sess) k
          where k ~ '^\d{4}-\d{2}-\d{2}$' and public.coach_date(k) <= v_hoje
            and public.coach_day_done(sess -> k);
        select count(*) into v_semana
          from jsonb_object_keys(sess) k
          where k ~ '^\d{4}-\d{2}-\d{2}$' and public.coach_date(k) > v_hoje - 7 and public.coach_date(k) <= v_hoje
            and public.coach_day_done(sess -> k);
        if coalesce((perms->>'ver_esforco_dor')::boolean, false) then
          select max(public.coach_num(c.value->>'dor')) into v_dor
            from jsonb_object_keys(sess) k,
                 lateral jsonb_each(case when jsonb_typeof(sess->k->'cargas') = 'object' then sess->k->'cargas' else '{}'::jsonb end) c
            where k ~ '^\d{4}-\d{2}-\d{2}$' and public.coach_date(k) > v_hoje - 3 and public.coach_date(k) <= v_hoje
              and jsonb_typeof(c.value) = 'object';
        end if;
        item := item || jsonb_build_object(
          'dias7', to_jsonb(dias), 'treinos_7d', v_semana, 'ultimo_treino', v_ultimo,
          'dias_sem_treino', case when v_ultimo is null then null else v_hoje - v_ultimo end,
          'dor_max_recente', v_dor);
      else
        item := item || jsonb_build_object('bloqueado', true);
      end if;
      select id, versao, status, created_at into v_ass
        from public.coach_assignments where link_id = r.id order by created_at desc limit 1;
      if found then
        item := item || jsonb_build_object('ultimo_envio', jsonb_build_object(
          'id', v_ass.id, 'versao', v_ass.versao, 'status', v_ass.status, 'quando', v_ass.created_at));
      end if;
      item := item || jsonb_build_object('nao_lidas', (
        select count(*) from public.coach_notes n
        where n.link_id = r.id and n.author_id <> auth.uid() and not n.lida));
    end if;
    out := out || jsonb_build_array(item);
  end loop;
  return out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Treinador: perfil do aluno (últimos p_dias, respeitando as permissões)
-- ---------------------------------------------------------------------------
create or replace function public.coach_student_detail(p_link uuid, p_dias int default 28)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l public.coach_links; a public.app_data; perms jsonb; v_hoje date := public.coach_hoje();
  sess jsonb := '{}'::jsonb; k text; j jsonb; dia jsonb; carg jsonb; c record;
  v_cargas boolean; v_ed boolean; out jsonb;
begin
  perform public.coach_assert_coach();
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if not found then raise exception 'vínculo não está ativo'; end if;
  perms := l.permissions;
  select * into a from public.app_data where user_id = l.student_id;
  out := jsonb_build_object(
    'link_id', l.id, 'nome', coalesce(nullif(a.display_name, ''), l.student_label, 'Aluno'),
    'aluno_desde', l.accepted_at, 'permissions', perms, 'gerado_em', now());
  if not coalesce((perms->>'ver_treinos')::boolean, false) then
    return out || jsonb_build_object('bloqueado', true);
  end if;
  v_cargas := coalesce((perms->>'ver_cargas')::boolean, false);
  v_ed := coalesce((perms->>'ver_esforco_dor')::boolean, false);
  for k, j in select key, value from jsonb_each(coalesce(a.sessions, '{}'::jsonb)) loop
    if k ~ '^\d{4}-\d{2}-\d{2}$' and public.coach_date(k) > v_hoje - least(coalesce(p_dias, 28), 90) and public.coach_date(k) <= v_hoje then
      dia := jsonb_build_object('feito', public.coach_day_done(j));
      if v_cargas and j ? 'log' then dia := dia || jsonb_build_object('log', j->'log'); end if;
      carg := '{}'::jsonb;
      if jsonb_typeof(j->'cargas') = 'object' then
        for c in select key, value from jsonb_each(j->'cargas') loop
          if jsonb_typeof(c.value) = 'object' then
            carg := carg || jsonb_build_object(c.key,
              (case when v_cargas then c.value - 'rpe' - 'dor' else
                 jsonb_build_object('duracaoMin', c.value->'duracaoMin', 'distanciaKm', c.value->'distanciaKm') end)
              || (case when v_ed then jsonb_strip_nulls(jsonb_build_object('rpe', c.value->'rpe', 'dor', c.value->'dor')) else '{}'::jsonb end));
          end if;
        end loop;
      end if;
      dia := dia || jsonb_build_object('cargas', carg);
      sess := sess || jsonb_build_object(k, dia);
    end if;
  end loop;
  out := out || jsonb_build_object('sessoes', sess, 'treinos', coalesce(a.treinos, '[]'::jsonb),
                                   'schedule', coalesce(a.schedule, '{}'::jsonb));
  if coalesce((perms->>'ver_corrida')::boolean, false) then
    out := out || jsonb_build_object('planos', coalesce(a.planos, '[]'::jsonb), 'atividades', coalesce(a.atividades, '[]'::jsonb));
  end if;
  insert into public.coach_audit (link_id, ator, acao) values (p_link, auth.uid(), 'ver_aluno');
  return out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Envio de semanas / fichas / corrida
-- ---------------------------------------------------------------------------
create or replace function public.coach_send_assignment(
  p_link uuid, p_tipo text, p_payload jsonb, p_mensagem text default null
) returns public.coach_assignments
language plpgsql security definer set search_path = public as $$
declare v_ver int; v_row public.coach_assignments;
begin
  perform public.coach_assert_coach();
  if not exists (select 1 from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo') then
    raise exception 'vínculo não está ativo (pausado ou encerrado)';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'conteúdo inválido'; end if;
  if pg_column_size(p_payload) > 200000 then raise exception 'conteúdo grande demais'; end if;
  select coalesce(max(versao), 0) + 1 into v_ver from public.coach_assignments where link_id = p_link and tipo = p_tipo;
  insert into public.coach_assignments (link_id, tipo, versao, payload, mensagem)
  values (p_link, p_tipo, v_ver, p_payload, nullif(left(trim(coalesce(p_mensagem, '')), 500), ''))
  returning * into v_row;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (p_link, auth.uid(), 'envio', jsonb_build_object('assignment', v_row.id, 'tipo', p_tipo, 'versao', v_ver));
  perform public.coach_log_event('semana_enviada', jsonb_build_object('tipo', p_tipo));
  return v_row;
end;
$$;

-- Treinador: histórico de envios de um aluno (status de entrega).
create or replace function public.coach_list_assignments(p_link uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  if not exists (select 1 from public.coach_links where id = p_link and coach_id = auth.uid()) then
    raise exception 'vínculo não encontrado';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'tipo', tipo, 'versao', versao, 'status', status, 'mensagem', mensagem,
      'motivo_recusa', motivo_recusa, 'created_at', created_at, 'seen_at', seen_at,
      'decided_at', decided_at, 'payload', payload) order by created_at desc)
    from public.coach_assignments where link_id = p_link), '[]'::jsonb);
end;
$$;

-- Aluno: o que chegou do treinador e ainda não foi decidido (mais o último aplicado, para comparar).
create or replace function public.coach_my_assignments()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'link_id', s.link_id, 'tipo', s.tipo, 'versao', s.versao, 'status', s.status,
      'mensagem', s.mensagem, 'created_at', s.created_at, 'payload', s.payload,
      'coach_nome', coalesce(p.nome_exibicao, 'Treinador')) order by s.created_at desc)
    from public.coach_assignments s
    join public.coach_links l on l.id = s.link_id
    left join public.coach_profiles p on p.user_id = l.coach_id
    where l.student_id = auth.uid() and l.status in ('ativo', 'pausado')
      and (s.status in ('enviado', 'visto', 'aceito', 'aplicado'))
      and s.created_at > now() - interval '90 days'
  ), '[]'::jsonb);
end;
$$;

-- Aluno: visto | aceito | recusado | aplicado
create or replace function public.coach_decide_assignment(p_id uuid, p_status text, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare s public.coach_assignments;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_status not in ('visto', 'aceito', 'recusado', 'aplicado') then raise exception 'status inválido'; end if;
  select s2.* into s from public.coach_assignments s2
    join public.coach_links l on l.id = s2.link_id
   where s2.id = p_id and l.student_id = auth.uid() and l.status in ('ativo', 'pausado') for update of s2;
  if not found then raise exception 'envio não encontrado'; end if;
  update public.coach_assignments set
      status = case when s.status in ('aceito', 'aplicado') and p_status = 'visto' then s.status else p_status end,
      seen_at = coalesce(seen_at, now()),
      decided_at = case when p_status in ('aceito', 'recusado', 'aplicado') then now() else decided_at end,
      motivo_recusa = case when p_status = 'recusado' then nullif(left(trim(coalesce(p_motivo, '')), 200), '') else motivo_recusa end
    where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Comentários por sessão
-- ---------------------------------------------------------------------------
create or replace function public.coach_add_note(p_link uuid, p_date date, p_session_ref text, p_texto text)
returns public.coach_notes
language plpgsql security definer set search_path = public as $$
declare v_row public.coach_notes;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.coach_links l
                 where l.id = p_link and l.status in ('ativo', 'pausado')
                   and (l.coach_id = auth.uid() or l.student_id = auth.uid())) then
    raise exception 'vínculo não encontrado';
  end if;
  insert into public.coach_notes (link_id, author_id, date, session_ref, texto)
  values (p_link, auth.uid(), p_date, left(p_session_ref, 80), left(trim(p_texto), 500))
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.coach_mark_notes_read(p_link uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_notes set lida = true
   where link_id = p_link and author_id <> auth.uid() and not lida and public.coach_is_party(p_link);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões de execução
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'coach\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Liberar um treinador (rodar manualmente, trocando o e-mail):
--   insert into public.coach_profiles (user_id, nome_exibicao, liberado)
--   select id, 'Dayanne', true from auth.users where email = 'EMAIL_DA_TREINADORA'
--   on conflict (user_id) do update set liberado = true;
-- Para retirar: update public.coach_profiles set liberado = false where user_id = '...';
-- ---------------------------------------------------------------------------

-- ======================================================================
-- coach_setup_v2.sql
-- ======================================================================
-- Modo treinador v2: autocadastro com aprovação, perfil do treinador, suspensão (congela vínculos),
-- convite do aluno ao treinador, feed de atividade e sem teto de alunos.
-- Requer coach_setup.sql. Idempotente (pode rodar de novo).

-- ---------------------------------------------------------------------------
-- Perfil do treinador: status, bio, CREF
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'coach_profiles' and column_name = 'status') then
    alter table public.coach_profiles add column status text not null default 'ativo'
      check (status in ('em_analise', 'ativo', 'suspenso'));
    -- quem já existia e estava sem liberação passa a "suspenso"
    update public.coach_profiles set status = case when liberado then 'ativo' else 'suspenso' end;
  end if;
end $$;
alter table public.coach_profiles add column if not exists bio text check (bio is null or char_length(bio) <= 160);
alter table public.coach_profiles add column if not exists cref text check (cref is null or char_length(cref) <= 30);
alter table public.coach_profiles add column if not exists pedido_em timestamptz not null default now();
alter table public.coach_profiles add column if not exists termos_versao text;
alter table public.coach_profiles add column if not exists termos_em timestamptz;
alter table public.coach_profiles add column if not exists motivo text;

-- vínculos congelados quando o treinador é suspenso
alter table public.coach_links drop constraint if exists coach_links_status_check;
alter table public.coach_links add constraint coach_links_status_check
  check (status in ('pendente', 'ativo', 'pausado', 'encerrado', 'recusado', 'congelado'));
alter table public.coach_links add column if not exists status_antes text;

-- liberado e status andam juntos; suspender congela os vínculos, reativar devolve
create or replace function public.coach_profile_sync()
returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    if new.liberado is distinct from old.liberado and new.status is not distinct from old.status then
      new.status := case when new.liberado then 'ativo' else 'suspenso' end;
    end if;
  end if;
  new.liberado := (new.status = 'ativo');
  return new;
end;
$$;
drop trigger if exists coach_profile_sync_trg on public.coach_profiles;
create trigger coach_profile_sync_trg before insert or update on public.coach_profiles
  for each row execute function public.coach_profile_sync();

create or replace function public.coach_profile_efeitos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'suspenso' and old.status is distinct from 'suspenso' then
    update public.coach_links set status_antes = status, status = 'congelado'
     where coach_id = new.user_id and status in ('ativo', 'pausado');
    insert into public.coach_audit (link_id, ator, acao, meta)
      select id, null, 'treinador_suspenso', jsonb_build_object('motivo', new.motivo) from public.coach_links
       where coach_id = new.user_id and status = 'congelado';
  elsif new.status = 'ativo' and old.status = 'suspenso' then
    update public.coach_links l set status = coalesce(l.status_antes, 'ativo'), status_antes = null
     where l.coach_id = new.user_id and l.status = 'congelado'
       and not exists (select 1 from public.coach_links x
                        where x.student_id = l.student_id and x.id <> l.id and x.status in ('ativo', 'pausado'));
  end if;
  return new;
end;
$$;
drop trigger if exists coach_profile_efeitos_trg on public.coach_profiles;
create trigger coach_profile_efeitos_trg after update on public.coach_profiles
  for each row execute function public.coach_profile_efeitos();

create or replace function public.coach_assert_coach()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.coach_profiles where user_id = auth.uid() and status = 'ativo') then
    raise exception 'treinador não liberado';
  end if;
end;
$$;

create or replace function public.coach_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.coach_profiles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v from public.coach_profiles where user_id = auth.uid();
  if not found then return null; end if;
  return jsonb_build_object('liberado', v.status = 'ativo', 'status', v.status, 'nome_exibicao', v.nome_exibicao,
                            'bio', v.bio, 'cref', v.cref, 'motivo', v.motivo, 'pedido_em', v.pedido_em);
end;
$$;

-- Qualquer conta pode pedir para virar treinador (fica "em análise" até o admin aprovar).
create or replace function public.coach_apply(p_nome text, p_bio text default null, p_cref text default null, p_termos boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.coach_profiles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome obrigatório'; end if;
  if not coalesce(p_termos, false) then raise exception 'aceite os termos do treinador'; end if;
  select * into v from public.coach_profiles where user_id = auth.uid();
  if found then
    update public.coach_profiles set nome_exibicao = left(trim(p_nome), 60),
           bio = nullif(left(trim(coalesce(p_bio, '')), 160), ''), cref = nullif(left(trim(coalesce(p_cref, '')), 30), '')
     where user_id = auth.uid();
  else
    insert into public.coach_profiles (user_id, nome_exibicao, liberado, status, bio, cref, termos_versao, termos_em)
    values (auth.uid(), left(trim(p_nome), 60), false, 'em_analise',
            nullif(left(trim(coalesce(p_bio, '')), 160), ''), nullif(left(trim(coalesce(p_cref, '')), 30), ''), 'v1', now());
    insert into public.coach_audit (link_id, ator, acao, meta) values (null, auth.uid(), 'termos_treinador', jsonb_build_object('versao', 'v1', 'maior_de_18', true));
    perform public.coach_log_event('treinador_pedido');
  end if;
  return public.coach_me();
end;
$$;

create or replace function public.coach_update_profile(p_nome text, p_bio text default null, p_cref text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome obrigatório'; end if;
  update public.coach_profiles set nome_exibicao = left(trim(p_nome), 60),
         bio = nullif(left(trim(coalesce(p_bio, '')), 160), ''), cref = nullif(left(trim(coalesce(p_cref, '')), 30), '')
   where user_id = auth.uid();
  if not found then raise exception 'perfil de treinador não encontrado'; end if;
  return public.coach_me();
end;
$$;

-- ---------------------------------------------------------------------------
-- Convite do treinador ao aluno: sem teto de alunos
-- ---------------------------------------------------------------------------
create or replace function public.coach_create_invite(p_label text default null)
returns public.coach_links
language plpgsql security definer set search_path = public as $$
declare
  v_code text; v_row public.coach_links; v_try int := 0;
begin
  perform public.coach_assert_coach();
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_links (coach_id, student_label, invite_code)
  values (auth.uid(), nullif(left(trim(coalesce(p_label, '')), 60), ''), v_code)
  returning * into v_row;
  insert into public.coach_audit (link_id, ator, acao) values (v_row.id, auth.uid(), 'convite_criado');
  perform public.coach_log_event('convite_criado');
  return v_row;
end;
$$;

-- prévia do convite agora mostra o perfil do treinador (só a quem tem o convite)
create or replace function public.coach_invite_preview(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; p public.coach_profiles; v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where invite_code = upper(trim(p_code));
  if not found then return null; end if;
  select * into p from public.coach_profiles where user_id = l.coach_id;
  v_status := case
    when l.status = 'pendente' and l.created_at < now() - interval '14 days' then 'expirado'
    when l.status = 'pendente' and coalesce(p.status, 'suspenso') <> 'ativo' then 'indisponivel'
    else l.status end;
  perform public.coach_log_event('convite_aberto');
  return jsonb_build_object(
    'link_id', l.id,
    'coach_nome', coalesce(p.nome_exibicao, 'Treinador'),
    'coach_uid', l.coach_id,
    'coach_bio', p.bio,
    'coach_cref', p.cref,
    'status', v_status,
    'eh_o_proprio', l.coach_id = auth.uid(),
    'ja_tem_treinador', exists (
      select 1 from public.coach_links x
      where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')),
    'treinador_atual', (
      select pp.nome_exibicao from public.coach_links x
      join public.coach_profiles pp on pp.user_id = x.coach_id
      where x.student_id = auth.uid() and x.status in ('ativo', 'pausado') limit 1)
  );
end;
$$;

create or replace function public.coach_accept_invite(p_code text, p_permissions jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; v_perms jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where invite_code = upper(trim(p_code)) for update;
  if not found then raise exception 'convite inválido'; end if;
  if l.coach_id = auth.uid() then raise exception 'você não pode ser aluno de si mesmo'; end if;
  if l.status <> 'pendente' then raise exception 'convite não está mais disponível'; end if;
  if l.created_at < now() - interval '14 days' then raise exception 'convite expirado'; end if;
  if not exists (select 1 from public.coach_profiles where user_id = l.coach_id and status = 'ativo') then
    raise exception 'convite não está mais disponível';
  end if;
  if exists (select 1 from public.coach_links x
             where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')) then
    raise exception 'ja_tem_treinador';
  end if;
  v_perms := public.coach_clean_perms(coalesce(p_permissions, '{}'::jsonb));
  update public.coach_links
     set student_id = auth.uid(), status = 'ativo', permissions = v_perms, accepted_at = now()
   where id = l.id;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (l.id, auth.uid(), 'consentimento', jsonb_build_object('texto_versao', 'v1', 'permissions', v_perms, 'maior_de_18', true));
  perform public.coach_log_event('convite_aceito');
  return jsonb_build_object('link_id', l.id, 'permissions', v_perms);
end;
$$;

-- Aluno: treinadores ativos, pausados ou congelados (com o perfil)
create or replace function public.coach_my_coach()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'link_id', l.id, 'status', l.status, 'permissions', l.permissions,
      'coach_nome', coalesce(p.nome_exibicao, 'Treinador'), 'coach_uid', l.coach_id,
      'coach_bio', p.bio, 'coach_cref', p.cref, 'coach_status', coalesce(p.status, 'suspenso'),
      'accepted_at', l.accepted_at
    ) order by l.accepted_at desc)
    from public.coach_links l
    left join public.coach_profiles p on p.user_id = l.coach_id
    where l.student_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado')
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Aluno convida o próprio treinador para o Movo
-- ---------------------------------------------------------------------------
create table if not exists public.coach_student_invites (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  invite_code text not null unique,
  permissions jsonb not null default '{"ver_treinos":true,"ver_cargas":true,"ver_esforco_dor":false,"ver_corrida":true}'::jsonb,
  status text not null default 'aberto' check (status in ('aberto', 'usado', 'cancelado')),
  coach_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  used_at timestamptz
);
create index if not exists coach_student_invites_student_idx on public.coach_student_invites (student_id, status);
alter table public.coach_student_invites enable row level security;
-- sem políticas: só pelas funções

create or replace function public.coach_student_invite_create(p_permissions jsonb default null, p_maior boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_perms jsonb; v_try int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not coalesce(p_maior, false) then raise exception 'precisa confirmar que tem 18 anos ou mais'; end if;
  if exists (select 1 from public.coach_links x where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')) then
    raise exception 'ja_tem_treinador';
  end if;
  v_perms := public.coach_clean_perms(coalesce(p_permissions, '{}'::jsonb));
  update public.coach_student_invites set status = 'cancelado' where student_id = auth.uid() and status = 'aberto';
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_student_invites where invite_code = v_code)
          and not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_student_invites (student_id, invite_code, permissions) values (auth.uid(), v_code, v_perms);
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (null, auth.uid(), 'convite_aluno_criado', jsonb_build_object('texto_versao', 'v1', 'permissions', v_perms, 'maior_de_18', true));
  perform public.coach_log_event('convite_aluno_criado');
  return jsonb_build_object('invite_code', v_code, 'permissions', v_perms, 'created_at', now());
end;
$$;

create or replace function public.coach_student_invite_open()
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_student_invites;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.coach_student_invites
   where student_id = auth.uid() and status = 'aberto' and created_at > now() - interval '14 days'
   order by created_at desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('invite_code', i.invite_code, 'permissions', i.permissions, 'created_at', i.created_at);
end;
$$;

create or replace function public.coach_student_invite_cancel()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_student_invites set status = 'cancelado' where student_id = auth.uid() and status = 'aberto';
end;
$$;

-- Prévia para quem recebeu o convite do aluno (o futuro treinador)
create or replace function public.coach_student_invite_preview(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_student_invites; n text; v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.coach_student_invites where invite_code = upper(trim(p_code));
  if not found then return null; end if;
  select nullif(display_name, '') into n from public.app_data where user_id = i.student_id;
  v_status := case when i.status = 'aberto' and i.created_at < now() - interval '14 days' then 'expirado' else i.status end;
  return jsonb_build_object(
    'aluno_nome', coalesce(n, 'Um aluno'), 'aluno_uid', i.student_id, 'status', v_status,
    'eh_o_proprio', i.student_id = auth.uid(),
    'meu_cadastro', (select status from public.coach_profiles where user_id = auth.uid()),
    'permissions', i.permissions);
end;
$$;

create or replace function public.coach_student_invite_accept(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_student_invites; v_link uuid; v_code text; v_try int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.coach_student_invites where invite_code = upper(trim(p_code)) for update;
  if not found then raise exception 'convite inválido'; end if;
  if i.student_id = auth.uid() then raise exception 'você não pode ser treinador de si mesmo'; end if;
  if i.status <> 'aberto' then raise exception 'convite não está mais disponível'; end if;
  if i.created_at < now() - interval '14 days' then raise exception 'convite expirado'; end if;
  if not exists (select 1 from public.coach_profiles where user_id = auth.uid() and status in ('em_analise', 'ativo')) then
    raise exception 'cadastro_pendente';
  end if;
  if exists (select 1 from public.coach_links x where x.student_id = i.student_id and x.status in ('ativo', 'pausado')) then
    raise exception 'o aluno já tem treinador';
  end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_links where invite_code = v_code)
          and not exists (select 1 from public.coach_student_invites where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_links (coach_id, student_id, status, invite_code, permissions, accepted_at)
  values (auth.uid(), i.student_id, 'ativo', v_code, i.permissions, now())
  returning id into v_link;
  update public.coach_student_invites set status = 'usado', coach_id = auth.uid(), used_at = now() where id = i.id;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (v_link, i.student_id, 'consentimento', jsonb_build_object('texto_versao', 'v1', 'permissions', i.permissions, 'maior_de_18', true, 'origem', 'convite_do_aluno'));
  perform public.coach_log_event('convite_aluno_aceito');
  return jsonb_build_object('link_id', v_link);
end;
$$;

-- ---------------------------------------------------------------------------
-- Feed de atividade do treinador (últimos p_dias)
-- ---------------------------------------------------------------------------
create or replace function public.coach_activity(p_dias int default 14)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hoje date := public.coach_hoje(); v_dias int := least(greatest(coalesce(p_dias, 14), 1), 60); out jsonb;
begin
  perform public.coach_assert_coach();
  with alunos as (
    select l.id as link_id, l.permissions, l.status, l.created_at as link_criado, l.accepted_at, l.invite_code,
           coalesce(nullif(a.display_name, ''), l.student_label, 'Aluno') as nome, a.sessions
      from public.coach_links l left join public.app_data a on a.user_id = l.student_id
     where l.coach_id = auth.uid() and l.status in ('pendente', 'ativo', 'pausado')
  ),
  treinos as (
    select al.link_id, al.nome, 'treino'::text as tipo,
           (public.coach_date(k) + time '12:00') at time zone 'America/Sao_Paulo' as quando,
           jsonb_build_object('data', k,
             'dor', case when coalesce((al.permissions->>'ver_esforco_dor')::boolean, false) then
                (select max(public.coach_num(c.value->>'dor')) from jsonb_each(case when jsonb_typeof(s.value->'cargas') = 'object' then s.value->'cargas' else '{}'::jsonb end) c where jsonb_typeof(c.value) = 'object') end) as dados
      from alunos al
      cross join lateral jsonb_each(coalesce(al.sessions, '{}'::jsonb)) s(key, value)
      cross join lateral (select s.key as k) kk
     where al.status = 'ativo' and coalesce((al.permissions->>'ver_treinos')::boolean, false)
       and kk.k ~ '^\d{4}-\d{2}-\d{2}$' and public.coach_date(kk.k) > v_hoje - v_dias and public.coach_date(kk.k) <= v_hoje
       and public.coach_day_done(s.value)
  ),
  envios as (
    select al.link_id, al.nome,
           case a.status when 'aceito' then 'aceitou' when 'aplicado' then 'aceitou' when 'recusado' then 'recusou' else 'viu' end as tipo,
           coalesce(a.decided_at, a.seen_at) as quando,
           jsonb_build_object('versao', a.versao, 'motivo', a.motivo_recusa) as dados
      from alunos al join public.coach_assignments a on a.link_id = al.link_id
     where a.status in ('aceito', 'aplicado', 'recusado', 'visto') and coalesce(a.decided_at, a.seen_at) > now() - make_interval(days => v_dias)
  ),
  notas as (
    select al.link_id, al.nome, 'nota'::text as tipo, n.created_at as quando,
           jsonb_build_object('texto', n.texto, 'data', n.date, 'lida', n.lida) as dados
      from alunos al join public.coach_notes n on n.link_id = al.link_id
     where n.author_id <> auth.uid() and n.created_at > now() - make_interval(days => v_dias)
  ),
  novos as (
    select al.link_id, al.nome, 'aluno_novo'::text as tipo, al.accepted_at as quando, '{}'::jsonb as dados
      from alunos al where al.status in ('ativo', 'pausado') and al.accepted_at > now() - make_interval(days => v_dias)
  ),
  convites as (
    select al.link_id, al.nome,
           case when al.link_criado < now() - interval '14 days' then 'convite_expirado' else 'convite_expirando' end as tipo,
           al.link_criado + interval '14 days' as quando,
           jsonb_build_object('invite_code', al.invite_code) as dados
      from alunos al
     where al.status = 'pendente' and al.link_criado < now() - interval '11 days'
  ),
  todos as (
    select * from treinos union all select * from envios union all select * from notas
    union all select * from novos union all select * from convites
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'quando', quando, 'link_id', link_id, 'nome', nome, 'dados', dados) order by quando desc), '[]'::jsonb)
    into out from (select * from todos where quando is not null order by quando desc limit 80) t;
  return out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin: fila de treinadores (só o e-mail admin)
-- ---------------------------------------------------------------------------
drop function if exists public.admin_coach_list();
create function public.admin_coach_list()
returns table (user_id uuid, email text, nome_exibicao text, liberado boolean, status text, bio text, cref text, pedido_em timestamptz, motivo text, alunos int)
language sql security definer set search_path = public, auth as $$
  select p.user_id, u.email::text, p.nome_exibicao, p.status = 'ativo', p.status, p.bio, p.cref, p.pedido_em, p.motivo,
         (select count(*)::int from public.coach_links l where l.coach_id = p.user_id and l.status in ('ativo', 'pausado', 'congelado'))
  from public.coach_profiles p
  join auth.users u on u.id = p.user_id
  where public.is_movo_admin()
  order by (p.status = 'em_analise') desc, p.pedido_em desc;
$$;

create or replace function public.admin_set_coach(p_email text, p_nome text, p_liberado boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if not public.is_movo_admin() then
    raise exception 'not allowed';
  end if;
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then raise exception 'usuario_nao_encontrado'; end if;
  insert into public.coach_profiles (user_id, nome_exibicao, liberado, status)
  values (v_id, coalesce(nullif(left(trim(coalesce(p_nome, '')), 60), ''), 'Treinador'), p_liberado, case when p_liberado then 'ativo' else 'suspenso' end)
  on conflict (user_id) do update set
    status = case when p_liberado then 'ativo' else 'suspenso' end,
    nome_exibicao = case when nullif(trim(coalesce(p_nome, '')), '') is not null then left(trim(p_nome), 60) else public.coach_profiles.nome_exibicao end;
  return true;
end;
$$;

-- aprovar | suspender | recusar um pedido (p_status: 'ativo' | 'suspenso')
create or replace function public.admin_coach_decide(p_user uuid, p_status text, p_motivo text default null)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_movo_admin() then
    raise exception 'not allowed';
  end if;
  if p_status not in ('ativo', 'suspenso') then raise exception 'status inválido'; end if;
  update public.coach_profiles set status = p_status,
         motivo = case when p_status = 'suspenso' then nullif(left(trim(coalesce(p_motivo, '')), 200), '') else null end
   where user_id = p_user;
  if not found then raise exception 'treinador não encontrado'; end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões de execução
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like 'coach\_%' or p.proname like 'admin\_coach\_%' or p.proname = 'admin_set_coach')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- coach_admin.sql
-- ======================================================================
-- Admin: liberar/retirar treinadores pelo painel (Configurações > Uso). Requer coach_setup.sql.
-- Só o e-mail admin consegue usar. Seguro rodar de novo.

drop function if exists public.admin_coach_list();
create function public.admin_coach_list()
returns table (user_id uuid, email text, nome_exibicao text, liberado boolean, alunos int)
language sql security definer set search_path = public, auth as $$
  select p.user_id, u.email::text, p.nome_exibicao, p.liberado,
         (select count(*)::int from public.coach_links l where l.coach_id = p.user_id and l.status in ('ativo','pausado'))
  from public.coach_profiles p
  join auth.users u on u.id = p.user_id
  where public.is_movo_admin()
  order by p.created_at desc;
$$;

create or replace function public.admin_set_coach(p_email text, p_nome text, p_liberado boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if not public.is_movo_admin() then
    raise exception 'not allowed';
  end if;
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then raise exception 'usuario_nao_encontrado'; end if;
  insert into public.coach_profiles (user_id, nome_exibicao, liberado)
  values (v_id, coalesce(nullif(left(trim(coalesce(p_nome, '')), 60), ''), 'Treinador'), p_liberado)
  on conflict (user_id) do update set
    liberado = p_liberado,
    nome_exibicao = case when nullif(trim(coalesce(p_nome, '')), '') is not null then left(trim(p_nome), 60) else public.coach_profiles.nome_exibicao end;
  return true;
end;
$$;

revoke execute on function public.admin_coach_list() from public, anon;
revoke execute on function public.admin_set_coach(text, text, boolean) from public, anon;
grant execute on function public.admin_coach_list() to authenticated;
grant execute on function public.admin_set_coach(text, text, boolean) to authenticated;

-- ======================================================================
-- coach_agenda_setup.sql
-- ======================================================================
-- Agenda do treinador (fase 1): compromissos (aula particular, coletiva, treino próprio, outros),
-- recorrência semanal, exceções por dia e janela de trabalho (horário livre = janela - compromissos).
-- Requer coach_setup.sql e coach_setup_v2.sql. Idempotente (pode rodar de novo).
-- Horários são locais (America/Sao_Paulo), sem fuso: a agenda é presencial.

-- ---------------------------------------------------------------------------
-- Tabelas (RLS ligado, sem políticas: tudo passa pelas funções abaixo)
-- ---------------------------------------------------------------------------
create table if not exists public.coach_agenda_itens (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('particular', 'coletiva', 'treino_proprio', 'outro')),
  titulo text check (titulo is null or char_length(titulo) <= 60),
  hora_inicio time not null,
  duracao_min int not null check (duracao_min between 5 and 600),
  dias_semana smallint[],            -- 0=domingo ... 6=sábado (recorrente)
  data_unica date,                   -- compromisso de um dia só
  inicio_em date not null,           -- recorrência vale a partir daqui
  fim_em date,                       -- e até aqui (inclusive); nulo = sem fim
  created_at timestamptz not null default now(),
  constraint coach_agenda_itens_recorrencia check (
    (data_unica is not null and dias_semana is null)
    or (data_unica is null and dias_semana is not null and cardinality(dias_semana) between 1 and 7)
  ),
  constraint coach_agenda_itens_fim check (fim_em is null or fim_em >= inicio_em)
);
create index if not exists coach_agenda_itens_coach_idx on public.coach_agenda_itens (coach_id);
alter table public.coach_agenda_itens enable row level security;

-- exceções de uma data (cancelada agora; feita/faltou/remarcada nas próximas fases)
create table if not exists public.coach_agenda_ocorrencias (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.coach_agenda_itens(id) on delete cascade,
  data date not null,
  status text not null check (status in ('cancelada', 'feita', 'faltou', 'remarcada')),
  created_at timestamptz not null default now(),
  unique (item_id, data)
);
alter table public.coach_agenda_ocorrencias enable row level security;

create table if not exists public.coach_agenda_config (
  coach_id uuid primary key references auth.users(id) on delete cascade,
  janela jsonb not null default '{}'::jsonb,   -- {"1":[["06:00","12:00"],["16:00","21:00"]], ...} chave = dia da semana
  duracao_padrao int not null default 60 check (duracao_padrao between 5 and 600),
  updated_at timestamptz not null default now()
);
alter table public.coach_agenda_config enable row level security;

-- ---------------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_listar(p_ini date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg public.coach_agenda_config; itens jsonb; ocs jsonb;
begin
  perform public.coach_assert_coach();
  if p_ini is null or p_fim is null or p_fim < p_ini or p_fim - p_ini > 62 then
    raise exception 'período inválido';
  end if;
  select * into cfg from public.coach_agenda_config where coach_id = auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'tipo', i.tipo, 'titulo', i.titulo,
           'hora', to_char(i.hora_inicio, 'HH24:MI'), 'duracao', i.duracao_min,
           'dias', to_jsonb(i.dias_semana), 'data', i.data_unica,
           'inicio_em', i.inicio_em, 'fim_em', i.fim_em) order by i.hora_inicio, i.created_at), '[]'::jsonb)
    into itens
    from public.coach_agenda_itens i
   where i.coach_id = auth.uid()
     and ((i.data_unica is not null and i.data_unica between p_ini and p_fim)
       or (i.data_unica is null and i.inicio_em <= p_fim and (i.fim_em is null or i.fim_em >= p_ini)));
  select coalesce(jsonb_agg(jsonb_build_object('item_id', o.item_id, 'data', o.data, 'status', o.status)), '[]'::jsonb)
    into ocs
    from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id
   where i.coach_id = auth.uid() and o.data between p_ini and p_fim;
  return jsonb_build_object(
    'hoje', public.coach_hoje(),
    'itens', itens,
    'ocorrencias', ocs,
    'janela', coalesce(cfg.janela, '{}'::jsonb),
    'duracao_padrao', coalesce(cfg.duracao_padrao, 60));
end;
$$;

create or replace function public.coach_agenda_salvar(
  p_id uuid, p_tipo text, p_titulo text, p_hora text, p_duracao int,
  p_dias int[], p_data date, p_inicio date default null, p_fim date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hora time; v_dias smallint[]; v_titulo text := nullif(btrim(coalesce(p_titulo, '')), ''); v_id uuid;
        v_inicio date; v_total int;
begin
  perform public.coach_assert_coach();
  if p_tipo not in ('particular', 'coletiva', 'treino_proprio', 'outro') then raise exception 'tipo inválido'; end if;
  if v_titulo is not null and char_length(v_titulo) > 60 then raise exception 'título longo demais'; end if;
  if p_hora !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'horário inválido'; end if;
  v_hora := p_hora::time;
  if p_duracao is null or p_duracao < 5 or p_duracao > 600 then raise exception 'duração inválida'; end if;
  if p_dias is not null and cardinality(p_dias) > 0 then
    if exists (select 1 from unnest(p_dias) d where d < 0 or d > 6) then raise exception 'dia da semana inválido'; end if;
    select array_agg(distinct d::smallint order by d::smallint) into v_dias from unnest(p_dias) d;
    if p_data is not null then raise exception 'use dias ou data, não os dois'; end if;
  elsif p_data is null then
    raise exception 'informe a data ou os dias da semana';
  end if;
  v_inicio := coalesce(p_inicio, public.coach_hoje());
  if p_fim is not null and p_fim < v_inicio then raise exception 'fim antes do início'; end if;

  if p_id is null then
    select count(*) into v_total from public.coach_agenda_itens where coach_id = auth.uid();
    if v_total >= 500 then raise exception 'limite de compromissos atingido'; end if;
    insert into public.coach_agenda_itens (coach_id, tipo, titulo, hora_inicio, duracao_min, dias_semana, data_unica, inicio_em, fim_em)
    values (auth.uid(), p_tipo, v_titulo, v_hora, p_duracao, v_dias, case when v_dias is null then p_data end, v_inicio, p_fim)
    returning id into v_id;
  else
    update public.coach_agenda_itens
       set tipo = p_tipo, titulo = v_titulo, hora_inicio = v_hora, duracao_min = p_duracao,
           dias_semana = v_dias, data_unica = case when v_dias is null then p_data end,
           inicio_em = coalesce(p_inicio, inicio_em), fim_em = p_fim
     where id = p_id and coach_id = auth.uid()
    returning id into v_id;
    if v_id is null then raise exception 'compromisso não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.coach_agenda_apagar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  delete from public.coach_agenda_itens where id = p_id and coach_id = auth.uid();
end;
$$;

-- "só esta": cancela uma data de um compromisso recorrente
create or replace function public.coach_agenda_cancelar_dia(p_item uuid, p_data date)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  if not exists (select 1 from public.coach_agenda_itens where id = p_item and coach_id = auth.uid()) then
    raise exception 'compromisso não encontrado';
  end if;
  insert into public.coach_agenda_ocorrencias (item_id, data, status) values (p_item, p_data, 'cancelada')
  on conflict (item_id, data) do update set status = 'cancelada';
end;
$$;

-- "esta e as próximas": a série termina no dia anterior (e some se ainda nem tinha começado)
create or replace function public.coach_agenda_encerrar_serie(p_item uuid, p_a_partir date)
returns void language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens;
begin
  perform public.coach_assert_coach();
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if p_a_partir <= i.inicio_em then
    delete from public.coach_agenda_itens where id = i.id;
  else
    update public.coach_agenda_itens set fim_em = p_a_partir - 1 where id = i.id;
  end if;
end;
$$;

create or replace function public.coach_agenda_config_salvar(p_janela jsonb, p_duracao int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; faixa jsonb; v_ini time; v_fim time; v_norm jsonb := '{}'::jsonb; v_lista jsonb;
begin
  perform public.coach_assert_coach();
  if p_duracao is null or p_duracao < 5 or p_duracao > 600 then raise exception 'duração inválida'; end if;
  if p_janela is null or jsonb_typeof(p_janela) <> 'object' then raise exception 'janela inválida'; end if;
  for k in select jsonb_object_keys(p_janela) loop
    if k !~ '^[0-6]$' then raise exception 'dia da semana inválido'; end if;
    if jsonb_typeof(p_janela->k) <> 'array' or jsonb_array_length(p_janela->k) > 6 then raise exception 'faixas inválidas'; end if;
    v_lista := '[]'::jsonb;
    for faixa in select * from jsonb_array_elements(p_janela->k) loop
      if jsonb_typeof(faixa) <> 'array' or jsonb_array_length(faixa) <> 2
         or (faixa->>0) !~ '^([01]\d|2[0-3]):[0-5]\d$' or (faixa->>1) !~ '^([01]\d|2[0-3]):[0-5]\d$' then
        raise exception 'faixa inválida';
      end if;
      v_ini := (faixa->>0)::time; v_fim := (faixa->>1)::time;
      if v_fim <= v_ini then raise exception 'faixa termina antes de começar'; end if;
      v_lista := v_lista || jsonb_build_array(faixa);
    end loop;
    v_norm := v_norm || jsonb_build_object(k, v_lista);
  end loop;
  insert into public.coach_agenda_config (coach_id, janela, duracao_padrao, updated_at)
  values (auth.uid(), v_norm, p_duracao, now())
  on conflict (coach_id) do update set janela = excluded.janela, duracao_padrao = excluded.duracao_padrao, updated_at = now();
  return jsonb_build_object('janela', v_norm, 'duracao_padrao', p_duracao);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões de execução (mesmo padrão das demais funções coach_*)
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'coach\_agenda\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- coach_agenda_v2.sql
-- ======================================================================
-- Agenda do treinador, fase 2: alunos da agenda, presença (aconteceu/faltou), remarcar,
-- editar "só esta" / "esta e as próximas". Requer coach_agenda_setup.sql. Idempotente.

-- ---------------------------------------------------------------------------
-- Alunos da agenda (com ou sem Movo). Dado do próprio treinador, só ele vê.
-- ---------------------------------------------------------------------------
create table if not exists public.coach_agenda_pessoas (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  email text check (email is null or char_length(email) <= 120),
  telefone text check (telefone is null or telefone ~ '^\d{8,13}$'),
  link_id uuid references public.coach_links(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists coach_agenda_pessoas_coach_idx on public.coach_agenda_pessoas (coach_id);
alter table public.coach_agenda_pessoas enable row level security;

alter table public.coach_agenda_itens
  add column if not exists pessoa_id uuid references public.coach_agenda_pessoas(id) on delete set null;

-- compromissos "particular" da fase 1 (só com nome digitado) viram alunos da agenda
insert into public.coach_agenda_pessoas (coach_id, nome)
select distinct on (i.coach_id, lower(i.titulo)) i.coach_id, i.titulo
  from public.coach_agenda_itens i
 where i.tipo = 'particular' and i.titulo is not null and i.pessoa_id is null
   and not exists (select 1 from public.coach_agenda_pessoas p where p.coach_id = i.coach_id and lower(p.nome) = lower(i.titulo));
update public.coach_agenda_itens i set pessoa_id = p.id, titulo = null
  from public.coach_agenda_pessoas p
 where i.tipo = 'particular' and i.pessoa_id is null and i.titulo is not null
   and p.coach_id = i.coach_id and lower(p.nome) = lower(i.titulo);

-- ---------------------------------------------------------------------------
-- Listar (agora com alunos, contagem de aulas feitas/faltas e título calculado)
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_listar(p_ini date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg public.coach_agenda_config; itens jsonb; ocs jsonb; pes jsonb;
begin
  perform public.coach_assert_coach();
  if p_ini is null or p_fim is null or p_fim < p_ini or p_fim - p_ini > 62 then
    raise exception 'período inválido';
  end if;
  select * into cfg from public.coach_agenda_config where coach_id = auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'tipo', i.tipo, 'titulo', coalesce(p.nome, i.titulo), 'pessoa_id', i.pessoa_id,
           'hora', to_char(i.hora_inicio, 'HH24:MI'), 'duracao', i.duracao_min,
           'dias', to_jsonb(i.dias_semana), 'data', i.data_unica,
           'inicio_em', i.inicio_em, 'fim_em', i.fim_em) order by i.hora_inicio, i.created_at), '[]'::jsonb)
    into itens
    from public.coach_agenda_itens i left join public.coach_agenda_pessoas p on p.id = i.pessoa_id
   where i.coach_id = auth.uid()
     and ((i.data_unica is not null and i.data_unica between p_ini and p_fim)
       or (i.data_unica is null and i.inicio_em <= p_fim and (i.fim_em is null or i.fim_em >= p_ini)));
  select coalesce(jsonb_agg(jsonb_build_object('item_id', o.item_id, 'data', o.data, 'status', o.status)), '[]'::jsonb)
    into ocs
    from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id
   where i.coach_id = auth.uid() and o.data between p_ini and p_fim;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'nome', p.nome, 'email', p.email, 'telefone', p.telefone, 'link_id', p.link_id,
           'feitas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'feita'),
           'faltas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'faltou'))
         order by lower(p.nome)), '[]'::jsonb)
    into pes
    from public.coach_agenda_pessoas p where p.coach_id = auth.uid();
  return jsonb_build_object(
    'hoje', public.coach_hoje(),
    'itens', itens,
    'ocorrencias', ocs,
    'pessoas', pes,
    'janela', coalesce(cfg.janela, '{}'::jsonb),
    'duracao_padrao', coalesce(cfg.duracao_padrao, 60));
end;
$$;

-- ---------------------------------------------------------------------------
-- Alunos da agenda: criar/editar e apagar
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_pessoa_salvar(p_id uuid, p_nome text, p_email text default null, p_telefone text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nome text := btrim(coalesce(p_nome, '')); v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
        v_tel text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''); v_id uuid; v_total int;
begin
  perform public.coach_assert_coach();
  if char_length(v_nome) < 1 or char_length(v_nome) > 60 then raise exception 'nome inválido'; end if;
  if v_email is not null and (char_length(v_email) > 120 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'e-mail inválido'; end if;
  if v_tel is not null then
    if left(v_tel, 2) = '55' and char_length(v_tel) > 11 then v_tel := substr(v_tel, 3); end if;
    if v_tel !~ '^\d{10,11}$' then raise exception 'telefone inválido'; end if;
  end if;
  if p_id is null then
    select count(*) into v_total from public.coach_agenda_pessoas where coach_id = auth.uid();
    if v_total >= 300 then raise exception 'limite de alunos na agenda atingido'; end if;
    insert into public.coach_agenda_pessoas (coach_id, nome, email, telefone) values (auth.uid(), v_nome, v_email, v_tel) returning id into v_id;
  else
    update public.coach_agenda_pessoas set nome = v_nome, email = v_email, telefone = v_tel
     where id = p_id and coach_id = auth.uid() returning id into v_id;
    if v_id is null then raise exception 'aluno não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id, 'nome', v_nome, 'email', v_email, 'telefone', v_tel);
end;
$$;

-- apagar o aluno mantém as aulas na agenda, com o nome em texto
create or replace function public.coach_agenda_pessoa_apagar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p public.coach_agenda_pessoas;
begin
  perform public.coach_assert_coach();
  select * into p from public.coach_agenda_pessoas where id = p_id and coach_id = auth.uid();
  if p.id is null then return; end if;
  update public.coach_agenda_itens set titulo = p.nome where pessoa_id = p.id and coach_id = auth.uid();
  delete from public.coach_agenda_pessoas where id = p.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Salvar compromisso (agora com aluno). Troca a assinatura da fase 1.
-- ---------------------------------------------------------------------------
drop function if exists public.coach_agenda_salvar(uuid, text, text, text, int, int[], date, date, date);

create or replace function public.coach_agenda_salvar(
  p_id uuid, p_tipo text, p_titulo text, p_hora text, p_duracao int,
  p_dias int[], p_data date, p_inicio date default null, p_fim date default null, p_pessoa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hora time; v_dias smallint[]; v_titulo text := nullif(btrim(coalesce(p_titulo, '')), ''); v_id uuid;
        v_inicio date; v_total int; v_pessoa uuid := p_pessoa;
begin
  perform public.coach_assert_coach();
  if p_tipo not in ('particular', 'coletiva', 'treino_proprio', 'outro') then raise exception 'tipo inválido'; end if;
  if v_titulo is not null and char_length(v_titulo) > 60 then raise exception 'título longo demais'; end if;
  if p_hora !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'horário inválido'; end if;
  v_hora := p_hora::time;
  if p_duracao is null or p_duracao < 5 or p_duracao > 600 then raise exception 'duração inválida'; end if;
  if p_dias is not null and cardinality(p_dias) > 0 then
    if exists (select 1 from unnest(p_dias) d where d < 0 or d > 6) then raise exception 'dia da semana inválido'; end if;
    select array_agg(distinct d::smallint order by d::smallint) into v_dias from unnest(p_dias) d;
    if p_data is not null then raise exception 'use dias ou data, não os dois'; end if;
  elsif p_data is null then
    raise exception 'informe a data ou os dias da semana';
  end if;
  if p_tipo <> 'particular' then v_pessoa := null; end if;
  if v_pessoa is not null then
    if not exists (select 1 from public.coach_agenda_pessoas where id = v_pessoa and coach_id = auth.uid()) then raise exception 'aluno não encontrado'; end if;
    v_titulo := null;
  end if;
  v_inicio := coalesce(p_inicio, public.coach_hoje());
  if p_fim is not null and p_fim < v_inicio then raise exception 'fim antes do início'; end if;

  if p_id is null then
    select count(*) into v_total from public.coach_agenda_itens where coach_id = auth.uid();
    if v_total >= 500 then raise exception 'limite de compromissos atingido'; end if;
    insert into public.coach_agenda_itens (coach_id, tipo, titulo, pessoa_id, hora_inicio, duracao_min, dias_semana, data_unica, inicio_em, fim_em)
    values (auth.uid(), p_tipo, v_titulo, v_pessoa, v_hora, p_duracao, v_dias, case when v_dias is null then p_data end, v_inicio, p_fim)
    returning id into v_id;
  else
    update public.coach_agenda_itens
       set tipo = p_tipo, titulo = v_titulo, pessoa_id = v_pessoa, hora_inicio = v_hora, duracao_min = p_duracao,
           dias_semana = v_dias, data_unica = case when v_dias is null then p_data end,
           inicio_em = coalesce(p_inicio, inicio_em), fim_em = p_fim
     where id = p_id and coach_id = auth.uid()
    returning id into v_id;
    if v_id is null then raise exception 'compromisso não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

-- o compromisso ocorre nesta data? (ignora exceções)
create or replace function public.coach_agenda_ocorre(i public.coach_agenda_itens, d date)
returns boolean language sql immutable as $$
  select case when i.data_unica is not null then i.data_unica = d
              else d >= i.inicio_em and (i.fim_em is null or d <= i.fim_em) and extract(dow from d)::int = any (i.dias_semana::int[]) end;
$$;

-- ---------------------------------------------------------------------------
-- Presença: aconteceu / faltou (nulo desfaz). Só até hoje.
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_marcar(p_item uuid, p_data date, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; o public.coach_agenda_ocorrencias;
begin
  perform public.coach_assert_coach();
  if p_status is not null and p_status not in ('feita', 'faltou') then raise exception 'status inválido'; end if;
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if not public.coach_agenda_ocorre(i, p_data) then raise exception 'o compromisso não ocorre nesta data'; end if;
  if p_data > public.coach_hoje() then raise exception 'só dá para marcar aulas até hoje'; end if;
  select * into o from public.coach_agenda_ocorrencias where item_id = p_item and data = p_data;
  if o.id is not null and o.status in ('cancelada', 'remarcada') then raise exception 'essa aula foi cancelada ou remarcada'; end if;
  if p_status is null then
    delete from public.coach_agenda_ocorrencias where item_id = p_item and data = p_data and status in ('feita', 'faltou');
  else
    insert into public.coach_agenda_ocorrencias (item_id, data, status) values (p_item, p_data, p_status)
    on conflict (item_id, data) do update set status = excluded.status;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Remarcar uma aula para outra data/hora (a original fica "remarcada")
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_remarcar(p_item uuid, p_data date, p_nova_data date, p_nova_hora text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; v_id uuid; v_total int;
begin
  perform public.coach_assert_coach();
  if p_nova_hora !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'horário inválido'; end if;
  if p_nova_data is null then raise exception 'informe a nova data'; end if;
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if not public.coach_agenda_ocorre(i, p_data) then raise exception 'o compromisso não ocorre nesta data'; end if;
  if i.data_unica is not null then
    update public.coach_agenda_itens set data_unica = p_nova_data, inicio_em = least(inicio_em, p_nova_data), hora_inicio = p_nova_hora::time where id = i.id;
    delete from public.coach_agenda_ocorrencias where item_id = i.id and status in ('feita', 'faltou');
    return jsonb_build_object('id', i.id);
  end if;
  select count(*) into v_total from public.coach_agenda_itens where coach_id = auth.uid();
  if v_total >= 500 then raise exception 'limite de compromissos atingido'; end if;
  insert into public.coach_agenda_ocorrencias (item_id, data, status) values (i.id, p_data, 'remarcada')
  on conflict (item_id, data) do update set status = 'remarcada';
  insert into public.coach_agenda_itens (coach_id, tipo, titulo, pessoa_id, hora_inicio, duracao_min, data_unica, inicio_em)
  values (auth.uid(), i.tipo, i.titulo, i.pessoa_id, p_nova_hora::time, i.duracao_min, p_nova_data, p_nova_data)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Editar só uma data de uma série (cancela a data e cria um compromisso avulso)
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_editar_dia(
  p_item uuid, p_data date, p_tipo text, p_titulo text, p_hora text, p_duracao int, p_pessoa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; v_new jsonb;
begin
  perform public.coach_assert_coach();
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if i.data_unica is not null or not public.coach_agenda_ocorre(i, p_data) then raise exception 'o compromisso não ocorre nesta data'; end if;
  v_new := public.coach_agenda_salvar(null, p_tipo, p_titulo, p_hora, p_duracao, null, p_data, p_data, null, p_pessoa);
  insert into public.coach_agenda_ocorrencias (item_id, data, status) values (i.id, p_data, 'cancelada')
  on conflict (item_id, data) do update set status = 'cancelada';
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Editar "esta e as próximas": a série antiga termina no dia anterior e nasce uma nova daqui pra frente
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_dividir(
  p_item uuid, p_a_partir date, p_tipo text, p_titulo text, p_hora text, p_duracao int, p_dias int[], p_pessoa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; v_new jsonb; v_id uuid;
begin
  perform public.coach_assert_coach();
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if i.data_unica is not null then raise exception 'só séries podem ser divididas'; end if;
  if p_a_partir <= i.inicio_em then
    return public.coach_agenda_salvar(i.id, p_tipo, p_titulo, p_hora, p_duracao, p_dias, null, null, i.fim_em, p_pessoa);
  end if;
  v_new := public.coach_agenda_salvar(null, p_tipo, p_titulo, p_hora, p_duracao, p_dias, null, p_a_partir, i.fim_em, p_pessoa);
  v_id := (v_new->>'id')::uuid;
  update public.coach_agenda_ocorrencias set item_id = v_id where item_id = i.id and data >= p_a_partir;
  update public.coach_agenda_itens set fim_em = p_a_partir - 1 where id = i.id;
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões de execução
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'coach\_agenda\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- coach_agenda_v3.sql
-- ======================================================================
-- Agenda do treinador, fase 3: pacotes de aulas com saldo calculado sozinho.
-- Requer coach_agenda_setup.sql e coach_agenda_v2.sql. Idempotente.
-- Sem cobrança nem valores. A observação do pacote não deve guardar dado de saúde.

create table if not exists public.coach_agenda_pacotes (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  pessoa_id uuid not null references public.coach_agenda_pessoas(id) on delete cascade,
  total int not null check (total between 1 and 200),
  validade_dias int check (validade_dias is null or validade_dias between 1 and 730),
  falta_desconta boolean not null default true,
  inicio_em date not null,
  encerrado_em date,
  obs text check (obs is null or char_length(obs) <= 80),
  created_at timestamptz not null default now(),
  constraint coach_agenda_pacotes_fim check (encerrado_em is null or encerrado_em >= inicio_em - 1)
);
create index if not exists coach_agenda_pacotes_pessoa_idx on public.coach_agenda_pacotes (pessoa_id);
alter table public.coach_agenda_pacotes enable row level security;

-- aulas usadas no pacote: presenças (e faltas, se o pacote desconta) dentro do período do pacote
create or replace function public.coach_agenda_pacote_usadas(pk public.coach_agenda_pacotes)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int
    from public.coach_agenda_ocorrencias o
    join public.coach_agenda_itens i on i.id = o.item_id
   where i.pessoa_id = pk.pessoa_id
     and o.data >= pk.inicio_em
     and (pk.encerrado_em is null or o.data <= pk.encerrado_em)
     and (pk.validade_dias is null or o.data <= pk.inicio_em + pk.validade_dias)
     and (o.status = 'feita' or (o.status = 'faltou' and pk.falta_desconta));
$$;

create or replace function public.coach_agenda_listar(p_ini date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg public.coach_agenda_config; itens jsonb; ocs jsonb; pes jsonb;
begin
  perform public.coach_assert_coach();
  if p_ini is null or p_fim is null or p_fim < p_ini or p_fim - p_ini > 62 then
    raise exception 'período inválido';
  end if;
  select * into cfg from public.coach_agenda_config where coach_id = auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'tipo', i.tipo, 'titulo', coalesce(p.nome, i.titulo), 'pessoa_id', i.pessoa_id,
           'hora', to_char(i.hora_inicio, 'HH24:MI'), 'duracao', i.duracao_min,
           'dias', to_jsonb(i.dias_semana), 'data', i.data_unica,
           'inicio_em', i.inicio_em, 'fim_em', i.fim_em) order by i.hora_inicio, i.created_at), '[]'::jsonb)
    into itens
    from public.coach_agenda_itens i left join public.coach_agenda_pessoas p on p.id = i.pessoa_id
   where i.coach_id = auth.uid()
     and ((i.data_unica is not null and i.data_unica between p_ini and p_fim)
       or (i.data_unica is null and i.inicio_em <= p_fim and (i.fim_em is null or i.fim_em >= p_ini)));
  select coalesce(jsonb_agg(jsonb_build_object('item_id', o.item_id, 'data', o.data, 'status', o.status)), '[]'::jsonb)
    into ocs
    from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id
   where i.coach_id = auth.uid() and o.data between p_ini and p_fim;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'nome', p.nome, 'email', p.email, 'telefone', p.telefone, 'link_id', p.link_id,
           'feitas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'feita'),
           'faltas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'faltou'),
           'pacotes', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', k.id, 'total', k.total, 'validade_dias', k.validade_dias, 'falta_desconta', k.falta_desconta,
                       'inicio_em', k.inicio_em, 'encerrado_em', k.encerrado_em, 'obs', k.obs,
                       'usadas', public.coach_agenda_pacote_usadas(k),
                       'vence_em', case when k.validade_dias is null then null else k.inicio_em + k.validade_dias end)
                     order by k.inicio_em desc, k.created_at desc)
                from (select * from public.coach_agenda_pacotes where pessoa_id = p.id order by inicio_em desc, created_at desc limit 12) k
           ), '[]'::jsonb))
         order by lower(p.nome)), '[]'::jsonb)
    into pes
    from public.coach_agenda_pessoas p where p.coach_id = auth.uid();
  return jsonb_build_object(
    'hoje', public.coach_hoje(),
    'itens', itens,
    'ocorrencias', ocs,
    'pessoas', pes,
    'janela', coalesce(cfg.janela, '{}'::jsonb),
    'duracao_padrao', coalesce(cfg.duracao_padrao, 60));
end;
$$;

-- p_id nulo = pacote novo (encerra o pacote aberto do aluno na véspera do início); p_id = ajusta o existente
create or replace function public.coach_agenda_pacote_salvar(
  p_id uuid, p_pessoa uuid, p_total int, p_validade int default null,
  p_falta_desconta boolean default true, p_inicio date default null, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_obs text := nullif(btrim(coalesce(p_obs, '')), ''); v_inicio date; v_id uuid; v_n int;
begin
  perform public.coach_assert_coach();
  if p_total is null or p_total < 1 or p_total > 200 then raise exception 'total de aulas inválido'; end if;
  if p_validade is not null and (p_validade < 1 or p_validade > 730) then raise exception 'validade inválida'; end if;
  if v_obs is not null and char_length(v_obs) > 80 then raise exception 'observação longa demais'; end if;
  if p_id is null then
    if not exists (select 1 from public.coach_agenda_pessoas where id = p_pessoa and coach_id = auth.uid()) then
      raise exception 'aluno não encontrado';
    end if;
    select count(*) into v_n from public.coach_agenda_pacotes where pessoa_id = p_pessoa;
    if v_n >= 100 then raise exception 'limite de pacotes atingido'; end if;
    v_inicio := coalesce(p_inicio, public.coach_hoje());
    update public.coach_agenda_pacotes set encerrado_em = greatest(inicio_em - 1, v_inicio - 1)
     where pessoa_id = p_pessoa and coach_id = auth.uid() and encerrado_em is null;
    insert into public.coach_agenda_pacotes (coach_id, pessoa_id, total, validade_dias, falta_desconta, inicio_em, obs)
    values (auth.uid(), p_pessoa, p_total, p_validade, coalesce(p_falta_desconta, true), v_inicio, v_obs)
    returning id into v_id;
  else
    update public.coach_agenda_pacotes
       set total = p_total, validade_dias = p_validade, falta_desconta = coalesce(p_falta_desconta, true),
           inicio_em = coalesce(p_inicio, inicio_em), obs = v_obs
     where id = p_id and coach_id = auth.uid()
    returning id into v_id;
    if v_id is null then raise exception 'pacote não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.coach_agenda_pacote_encerrar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  update public.coach_agenda_pacotes set encerrado_em = greatest(inicio_em, public.coach_hoje())
   where id = p_id and coach_id = auth.uid() and encerrado_em is null;
end;
$$;

create or replace function public.coach_agenda_pacote_apagar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  delete from public.coach_agenda_pacotes where id = p_id and coach_id = auth.uid();
end;
$$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'coach\_agenda\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- coach_agenda_v4.sql
-- ======================================================================
-- Agenda do treinador, fase 4a: convidar o aluno da agenda para o Movo.
-- O convite (coach_links pendente) nasce amarrado ao aluno da agenda (coach_agenda_pessoas.link_id).
-- Quando o aluno aceita pelo fluxo de sempre, o vínculo já está feito: não precisa confirmar nada.
-- Requer coach_setup.sql, coach_setup_v2.sql e coach_agenda_v2.sql. Idempotente.

-- cria (ou reaproveita) o convite do aluno da agenda; devolve o código
create or replace function public.coach_agenda_pessoa_convidar(p_pessoa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.coach_agenda_pessoas; l public.coach_links; v_row public.coach_links;
begin
  perform public.coach_assert_coach();
  select * into p from public.coach_agenda_pessoas where id = p_pessoa and coach_id = auth.uid() for update;
  if p.id is null then raise exception 'aluno não encontrado'; end if;
  if p.link_id is not null then
    select * into l from public.coach_links where id = p.link_id and coach_id = auth.uid();
    if l.id is not null and l.status in ('ativo', 'pausado') then raise exception 'esse aluno já está no Movo'; end if;
    if l.id is not null and l.status = 'pendente' then
      if l.created_at < now() - interval '14 days' then
        v_row := public.coach_resend_invite(l.id);
      else
        v_row := l;
      end if;
      return jsonb_build_object('link_id', v_row.id, 'invite_code', v_row.invite_code);
    end if;
  end if;
  v_row := public.coach_create_invite(p.nome);
  update public.coach_agenda_pessoas set link_id = v_row.id where id = p.id;
  return jsonb_build_object('link_id', v_row.id, 'invite_code', v_row.invite_code);
end;
$$;

-- situação do convite/vínculo de cada aluno da agenda que já foi convidado
create or replace function public.coach_agenda_vinculos()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'pessoa_id', p.id,
             'link_id', l.id,
             'status', case when l.status = 'pendente' and l.created_at < now() - interval '14 days' then 'expirado' else l.status end,
             'codigo', case when l.status = 'pendente' and l.created_at >= now() - interval '14 days' then l.invite_code end))
      from public.coach_agenda_pessoas p
      join public.coach_links l on l.id = p.link_id and l.coach_id = auth.uid()
     where p.coach_id = auth.uid()), '[]'::jsonb);
end;
$$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'coach\_agenda\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- coach_agenda_v4b.sql
-- ======================================================================
-- Agenda do treinador, fase 4b: o treinador monta a semana de quem ainda tem convite pendente.
-- A semana fica guardada no vínculo e aparece para o aluno assim que ele aceita o convite.
-- Troca só a checagem de coach_send_assignment (antes exigia vínculo ativo). Idempotente.
create or replace function public.coach_send_assignment(
  p_link uuid, p_tipo text, p_payload jsonb, p_mensagem text default null
) returns public.coach_assignments
language plpgsql security definer set search_path = public as $$
declare v_ver int; v_row public.coach_assignments; v_status text; v_criado timestamptz;
begin
  perform public.coach_assert_coach();
  select status, created_at into v_status, v_criado from public.coach_links where id = p_link and coach_id = auth.uid();
  if v_status is null or v_status not in ('ativo', 'pendente') then
    raise exception 'vínculo não está ativo (pausado ou encerrado)';
  end if;
  if v_status = 'pendente' then
    if v_criado < now() - interval '14 days' then raise exception 'convite expirado: reenvie o convite antes de guardar o treino'; end if;
    if (select count(*) from public.coach_assignments where link_id = p_link) >= 20 then raise exception 'limite de semanas guardadas atingido'; end if;
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'conteúdo inválido'; end if;
  if pg_column_size(p_payload) > 200000 then raise exception 'conteúdo grande demais'; end if;
  select coalesce(max(versao), 0) + 1 into v_ver from public.coach_assignments where link_id = p_link and tipo = p_tipo;
  insert into public.coach_assignments (link_id, tipo, versao, payload, mensagem)
  values (p_link, p_tipo, v_ver, p_payload, nullif(left(trim(coalesce(p_mensagem, '')), 500), ''))
  returning * into v_row;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (p_link, auth.uid(), 'envio', jsonb_build_object('assignment', v_row.id, 'tipo', p_tipo, 'versao', v_ver, 'guardado_para_convite', v_status = 'pendente'));
  perform public.coach_log_event('semana_enviada', jsonb_build_object('tipo', p_tipo));
  return v_row;
end;
$$;

revoke execute on function public.coach_send_assignment(uuid, text, jsonb, text) from public, anon;
grant execute on function public.coach_send_assignment(uuid, text, jsonb, text) to authenticated;

-- ======================================================================
-- coach_agenda_v4d.sql
-- ======================================================================
-- Agenda do treinador, fase 4d: ligar o aluno da agenda ao aluno real que entrou por convite genérico.
-- O servidor compara (sem mostrar e-mail nem telefone do aluno ao treinador) e só SUGERE;
-- quem vincula é sempre o treinador, ao confirmar. Requer coach_agenda_v2.sql e coach_contato.sql. Idempotente.

create or replace function public.coach_agenda_norm(t text)
returns text language sql immutable as $$
  select regexp_replace(lower(translate(btrim(coalesce(t, '')),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g');
$$;

-- sugestões: alunos ativos do treinador ainda sem aluno da agenda ligado x alunos da agenda sem vínculo
create or replace function public.coach_agenda_sugestoes()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
  perform public.coach_assert_coach();
  return coalesce((
    with livres as (
      select l.id as link_id, l.student_id,
             coalesce(nullif(a.display_name, ''), l.student_label, 'Aluno') as aluno_nome,
             lower(btrim(u.email)) as mail, c.telefone as tel,
             public.coach_agenda_norm(a.display_name) as nome_norm
        from public.coach_links l
        join auth.users u on u.id = l.student_id
        left join public.app_data a on a.user_id = l.student_id
        left join public.user_contact c on c.user_id = l.student_id
       where l.coach_id = auth.uid() and l.status = 'ativo' and l.student_id is not null
         and not exists (select 1 from public.coach_agenda_pessoas x where x.link_id = l.id)
    ), cand as (
      select v.link_id, v.aluno_nome, p.id as pessoa_id, p.nome as pessoa_nome,
             case when p.email is not null and lower(p.email) = v.mail then 'email'
                  when p.telefone is not null and p.telefone = v.tel then 'telefone'
                  when v.nome_norm <> '' and public.coach_agenda_norm(p.nome) = v.nome_norm then 'nome'
                  when v.nome_norm <> '' and split_part(public.coach_agenda_norm(p.nome), ' ', 1) = split_part(v.nome_norm, ' ', 1)
                       and position(' ' in public.coach_agenda_norm(p.nome)) > 0 and position(' ' in v.nome_norm) > 0
                       and regexp_replace(public.coach_agenda_norm(p.nome), '^.* ', '') = regexp_replace(v.nome_norm, '^.* ', '') then 'nome'
             end as motivo
        from livres v
        join public.coach_agenda_pessoas p on p.coach_id = auth.uid() and p.link_id is null
    )
    select jsonb_agg(jsonb_build_object(
             'link_id', link_id, 'aluno_nome', aluno_nome, 'pessoa_id', pessoa_id, 'pessoa_nome', pessoa_nome,
             'motivo', motivo, 'nivel', case when motivo in ('email', 'telefone') then 'forte' else 'fraca' end)
           order by case when motivo in ('email', 'telefone') then 0 else 1 end, aluno_nome)
      from cand where motivo is not null), '[]'::jsonb);
end;
$$;

-- confirmação do treinador: liga o aluno da agenda ao vínculo real (aulas, pacote e presenças passam a valer para ele)
create or replace function public.coach_agenda_vincular(p_pessoa uuid, p_link uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p public.coach_agenda_pessoas; l public.coach_links;
begin
  perform public.coach_assert_coach();
  select * into p from public.coach_agenda_pessoas where id = p_pessoa and coach_id = auth.uid() for update;
  if p.id is null then raise exception 'aluno não encontrado'; end if;
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status in ('ativo', 'pausado');
  if l.id is null then raise exception 'vínculo não encontrado'; end if;
  if exists (select 1 from public.coach_agenda_pessoas x where x.link_id = l.id and x.id <> p.id) then
    raise exception 'esse aluno do Movo já está ligado a outro aluno da agenda';
  end if;
  update public.coach_agenda_pessoas set link_id = l.id where id = p.id;
end;
$$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like 'coach\_agenda\_%')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- coach_contato.sql
-- ======================================================================
-- Telefone opcional de qualquer usuário (fase 4c da agenda do treinador).
-- Finalidade: contato do treinador (se houver vínculo e permissão "ver_contato") e avisos da conta.
-- Nunca marketing. Quem preenche pode apagar a qualquer momento. Idempotente.
-- Requer coach_setup.sql. Rode ANTES de reaplicar account_data_rights.sql.

create table if not exists public.user_contact (
  user_id uuid primary key references auth.users(id) on delete cascade,
  telefone text not null check (telefone ~ '^\d{10,11}$'),
  atualizado_em timestamptz not null default now()
);
alter table public.user_contact enable row level security;   -- sem políticas: só pelas funções abaixo

-- o próprio telefone (ou nulo)
create or replace function public.contact_get()
returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return (select telefone from public.user_contact where user_id = auth.uid());
end;
$$;

-- grava ou, com valor vazio, apaga o próprio telefone. Guarda só dígitos, com DDD, sem o 55.
create or replace function public.contact_set(p_telefone text)
returns text language plpgsql security definer set search_path = public as $$
declare v_tel text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_tel is null then
    delete from public.user_contact where user_id = auth.uid();
    return null;
  end if;
  if left(v_tel, 2) = '55' and char_length(v_tel) > 11 then v_tel := substr(v_tel, 3); end if;
  if v_tel !~ '^\d{10,11}$' then raise exception 'telefone inválido: use DDD + número'; end if;
  insert into public.user_contact (user_id, telefone, atualizado_em) values (auth.uid(), v_tel, now())
  on conflict (user_id) do update set telefone = excluded.telefone, atualizado_em = now();
  return v_tel;
end;
$$;

-- permissão nova no vínculo. Ausente = desligada (vínculos antigos nunca consentiram com isso).
create or replace function public.coach_clean_perms(p jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ver_treinos', coalesce((p->>'ver_treinos')::boolean, true),
    'ver_cargas', coalesce((p->>'ver_cargas')::boolean, true),
    'ver_esforco_dor', coalesce((p->>'ver_esforco_dor')::boolean, false),
    'ver_corrida', coalesce((p->>'ver_corrida')::boolean, true),
    'ver_contato', coalesce((p->>'ver_contato')::boolean, false)
  );
$$;

-- treinador: telefone do aluno, só com vínculo ativo e permissão ligada pelo aluno
create or replace function public.coach_aluno_contato(p_link uuid)
returns text language plpgsql security definer set search_path = public as $$
declare l public.coach_links;
begin
  perform public.coach_assert_coach();
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null or l.student_id is null then return null; end if;
  if not coalesce((l.permissions->>'ver_contato')::boolean, false) then return null; end if;
  return (select telefone from public.user_contact where user_id = l.student_id);
end;
$$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('contact_get', 'contact_set', 'coach_aluno_contato', 'coach_clean_perms')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- billing_base.sql
-- ======================================================================
-- Base de planos e cobrança do Movo (v158). DORMENTE: nada muda pra ninguém até o admin ligar as chaves.
-- Tudo no servidor; o app só lê `my_plan()`. Pode rodar de novo sem problema.
-- Rodar depois de feature_flags.sql / feature_flags_todos.sql e coach_setup_v2.sql.
--
-- Duas chaves (app_config), ambas desligadas por padrão:
--   billing_visivel : mostra "Meu plano" e os preços no app pra todo mundo (o admin sempre vê).
--   billing_limites : passa a aplicar os limites do plano (cota mensal de IA e nº de alunos do treinador).
-- Plano grátis = sem linha na tabela. Quem não tem assinatura válida cai no grátis.
-- Pagamento (Asaas) entra depois: o webhook só vai gravar/atualizar linhas em `assinaturas`.

insert into public.app_config (chave, valor, atualizado_em) values
  ('billing_visivel', 'false'::jsonb, now()),
  ('billing_limites', 'false'::jsonb, now())
on conflict (chave) do nothing;

create table if not exists public.assinaturas (
  user_id uuid not null references auth.users(id) on delete cascade,
  linha text not null check (linha in ('aluno', 'treinador')),
  plano text not null,
  ciclo text not null default 'mensal' check (ciclo in ('mensal', 'anual')),
  status text not null default 'ativa' check (status in ('teste', 'ativa', 'atrasada', 'cancelada')),
  origem text not null default 'manual' check (origem in ('manual', 'asaas')),
  gateway_ref text,
  teste_ate timestamptz,
  renova_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  primary key (user_id, linha),
  check ((linha = 'aluno' and plano = 'pro') or (linha = 'treinador' and plano in ('start', 'pro', 'studio')))
);
alter table public.assinaturas enable row level security;  -- sem policies: só as funções abaixo mexem

-- Interna: chave ligada?  ('visivel' | 'limites')
create or replace function public.billing_cfg(p_chave text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (valor)::text::boolean from public.app_config where chave = 'billing_' || p_chave), false);
$$;

-- Interna: plano valendo agora ('gratis' se não houver assinatura válida).
--   teste: até teste_ate | ativa: até renova_em + 3 dias de folga (webhook atrasado) | atrasada: 5 dias de folga
--   cancelada: segue valendo até o fim do período já pago.
create or replace function public.plano_efetivo(p_uid uuid, p_linha text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select a.plano from public.assinaturas a
    where a.user_id = p_uid and a.linha = p_linha
      and (   (a.status = 'teste' and a.teste_ate > now())
           or (a.status = 'ativa' and (a.renova_em is null or a.renova_em > now() - interval '3 days'))
           or (a.status = 'atrasada' and a.renova_em > now() - interval '5 days')
           or (a.status = 'cancelada' and a.renova_em > now()))
  ), 'gratis');
$$;

-- Interna: limites de cada plano (valores do business plan; é aqui que se muda preço/limite).
--   ia_mes: gerações de IA por tipo por mês | alunos: vínculos (convites pendentes + ativos + pausados)
create or replace function public.plano_limites(p_linha text, p_plano text)
returns jsonb
language sql
immutable
as $$
  select case p_linha || ':' || p_plano
    when 'aluno:pro'         then '{"ia_mes": 30}'::jsonb
    when 'treinador:start'   then '{"ia_mes": 10, "alunos": 10}'::jsonb
    when 'treinador:pro'     then '{"ia_mes": 30, "alunos": 30}'::jsonb
    when 'treinador:studio'  then '{"ia_mes": 30, "alunos": 80}'::jsonb
    when 'treinador:gratis'  then '{"ia_mes": 2, "alunos": 3}'::jsonb
    else '{"ia_mes": 2}'::jsonb  -- aluno:gratis
  end;
$$;

-- Interna: cota de IA que vale pra essa pessoa. Com `billing_limites` desligada, segue o valor que o app mandou (como hoje).
create or replace function public.ia_limite_efetivo(p_uid uuid, p_cliente int)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not public.billing_cfg('limites') then p_cliente
    else greatest(
      (public.plano_limites('aluno', public.plano_efetivo(p_uid, 'aluno'))->>'ia_mes')::int,
      (public.plano_limites('treinador', public.plano_efetivo(p_uid, 'treinador'))->>'ia_mes')::int
    )
  end;
$$;

revoke all on function public.billing_cfg(text) from public, anon, authenticated;
revoke all on function public.plano_efetivo(uuid, text) from public, anon, authenticated;
revoke all on function public.plano_limites(text, text) from public, anon, authenticated;
revoke all on function public.ia_limite_efetivo(uuid, int) from public, anon, authenticated;

-- O app pergunta o plano da pessoa logada (e se deve mostrar planos / aplicar limites).
create or replace function public.my_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  adm boolean;
  pa text; pt text;
  ra public.assinaturas; rt public.assinaturas;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  adm := public.movo_admin_uid(uid);
  pa := public.plano_efetivo(uid, 'aluno');
  pt := public.plano_efetivo(uid, 'treinador');
  select * into ra from public.assinaturas where user_id = uid and linha = 'aluno';
  select * into rt from public.assinaturas where user_id = uid and linha = 'treinador';
  return jsonb_build_object(
    'visivel', adm or public.billing_cfg('visivel'),
    'limites', public.billing_cfg('limites'),
    'admin', adm,
    'aluno', jsonb_build_object(
      'plano', pa, 'status', ra.status, 'ciclo', ra.ciclo, 'teste_ate', ra.teste_ate, 'renova_em', ra.renova_em,
      'ia_mes', (public.plano_limites('aluno', pa)->>'ia_mes')::int),
    'treinador', jsonb_build_object(
      'plano', pt, 'status', rt.status, 'ciclo', rt.ciclo, 'teste_ate', rt.teste_ate, 'renova_em', rt.renova_em,
      'alunos_max', (public.plano_limites('treinador', pt)->>'alunos')::int,
      'alunos_usados', (select count(*) from public.coach_links where coach_id = uid and status in ('pendente', 'ativo', 'pausado')))
  );
end;
$$;
revoke all on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;

-- Cota de IA: passa a respeitar o plano quando `billing_limites` estiver ligada (desligada = igual a hoje).
create or replace function public.ai_generation_usage(p_kind text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000;
  else max_per_month := public.ia_limite_efetivo(uid, max_per_month); end if;
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month, 'por_plano', public.billing_cfg('limites'));
end;
$$;

create or replace function public.reserve_ai_generation(p_kind text, p_label text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
  bloqueio text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  bloqueio := public.ai_bloqueio();
  if bloqueio is not null then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', bloqueio, 'usados', 0, 'limite', max_per_month,
      'mensagem', case bloqueio when 'desligada' then 'A IA está temporariamente desligada. Tente mais tarde.' else 'A IA atingiu o limite de uso de hoje. Tente amanhã.' end);
  end if;
  if p_kind = 'ajuste_semana' and not public.feature_allowed(uid, 'ajuste_semana') then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', 'sem_acesso', 'usados', 0, 'limite', max_per_month,
      'mensagem', 'O ajuste da semana com IA está em teste fechado e ainda não está liberado pra você.');
  end if;
  if public.movo_admin_uid(uid) then max_per_month := 1000000;
  else max_per_month := public.ia_limite_efetivo(uid, max_per_month); end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month, 'por_plano', public.billing_cfg('limites'));
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- Convite do treinador: com `billing_limites` ligada, respeita o nº de alunos do plano (desligada = sem teto, como hoje).
create or replace function public.coach_create_invite(p_label text default null)
returns public.coach_links
language plpgsql security definer set search_path = public as $$
declare
  v_code text; v_row public.coach_links; v_try int := 0; v_max int;
begin
  perform public.coach_assert_coach();
  if public.billing_cfg('limites')
     and not public.is_movo_admin() then
    v_max := (public.plano_limites('treinador', public.plano_efetivo(auth.uid(), 'treinador'))->>'alunos')::int;
    if (select count(*) from public.coach_links
         where coach_id = auth.uid() and status in ('pendente', 'ativo', 'pausado')) >= v_max then
      raise exception 'limite_plano_alunos';
    end if;
  end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_links (coach_id, student_label, invite_code)
  values (auth.uid(), nullif(left(trim(coalesce(p_label, '')), 60), ''), v_code)
  returning * into v_row;
  insert into public.coach_audit (link_id, ator, acao) values (v_row.id, auth.uid(), 'convite_criado');
  perform public.coach_log_event('convite_criado');
  return v_row;
end;
$$;

-- Admin: lê e muda as duas chaves.
create or replace function public.admin_billing_get()
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select jsonb_build_object('visivel', public.billing_cfg('visivel'), 'limites', public.billing_cfg('limites'))
  where public.is_movo_admin();
$$;

create or replace function public.admin_billing_set(p_chave text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if p_chave not in ('visivel', 'limites') then raise exception 'chave desconhecida'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('billing_' || p_chave, to_jsonb(coalesce(p_on, false)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end;
$$;

-- Admin: dá (ou tira) um plano a alguém pelo e-mail. Serve pra cortesia, beta pago combinado e pra testar.
--   p_plano 'gratis' remove. p_status 'teste' usa p_dias (padrão 14). 'ativa' com p_dias vale por esse tempo; sem p_dias não vence.
create or replace function public.admin_plan_set(
  p_email text, p_linha text, p_plano text,
  p_ciclo text default 'mensal', p_status text default 'ativa', p_dias int default null)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  alvo uuid;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select id into alvo from auth.users where lower(email) = lower(trim(p_email));
  if alvo is null then return 'usuario_nao_encontrado'; end if;
  if p_plano = 'gratis' then
    delete from public.assinaturas where user_id = alvo and linha = p_linha;
    return 'ok';
  end if;
  insert into public.assinaturas (user_id, linha, plano, ciclo, status, origem, teste_ate, renova_em)
  values (alvo, p_linha, p_plano, coalesce(p_ciclo, 'mensal'), coalesce(p_status, 'ativa'), 'manual',
          case when p_status = 'teste' then now() + make_interval(days => coalesce(p_dias, 14)) end,
          case when p_status is distinct from 'teste' and p_dias is not null then now() + make_interval(days => p_dias) end)
  on conflict (user_id, linha) do update
    set plano = excluded.plano, ciclo = excluded.ciclo, status = excluded.status, origem = 'manual',
        teste_ate = excluded.teste_ate, renova_em = excluded.renova_em, atualizado_em = now();
  return 'ok';
end;
$$;

create or replace function public.admin_plan_list()
returns table (email text, linha text, plano text, ciclo text, status text, origem text, teste_ate timestamptz, renova_em timestamptz)
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.email::text, a.linha, a.plano, a.ciclo, a.status, a.origem, a.teste_ate, a.renova_em
  from public.assinaturas a
  join auth.users u on u.id = a.user_id
  where public.is_movo_admin()
  order by a.atualizado_em desc;
$$;

revoke all on function public.admin_billing_get() from public, anon;
revoke all on function public.admin_billing_set(text, boolean) from public, anon;
revoke all on function public.admin_plan_set(text, text, text, text, text, int) from public, anon;
revoke all on function public.admin_plan_list() from public, anon;
grant execute on function public.admin_billing_get() to authenticated;
grant execute on function public.admin_billing_set(text, boolean) to authenticated;
grant execute on function public.admin_plan_set(text, text, text, text, text, int) to authenticated;
grant execute on function public.admin_plan_list() to authenticated;

-- ======================================================================
-- billing_trial_limites.sql
-- ======================================================================
-- Planos do usuário avulso (v159): teste de 30 dias, grátis limitado, Pro, e aluno de treinador pago = Pro.
-- DORMENTE como o billing_base.sql: só vale quando o admin liga "Aplicar os limites". Pode rodar de novo sem problema.
-- Rodar DEPOIS de billing_base.sql.
--
-- Regras do aluno (linha 'aluno'), na ordem:
--   admin                                          -> pro
--   assinatura Pro válida                          -> pro
--   vinculado a treinador com plano pago           -> pro (o plano do treinador cobre o aluno)
--   dentro do teste de 30 dias                     -> teste (tudo liberado)
--   senão                                          -> gratis (registro ilimitado, 2 fichas, gráficos de 3 meses, 1 IA/mês, não cria desafio)
-- O teste conta 30 dias a partir do maior entre: o cadastro, o dia em que o admin ligou os limites, e o fim do último vínculo
-- com treinador. Assim quem já usa hoje ganha 30 dias inteiros quando a cobrança começar.
-- Nenhum dado é apagado: o grátis só impede criar mais fichas, ver gráficos além de 3 meses e criar desafio.

-- Interna: quando os limites foram ligados pela última vez (null = nunca).
create or replace function public.billing_limites_desde()
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select nullif((select valor #>> '{}' from public.app_config where chave = 'billing_limites_desde'), '')::timestamptz;
$$;

-- Interna: fim do teste de 30 dias dessa pessoa.
create or replace function public.aluno_trial_fim(p_uid uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public, auth
as $$
  select greatest(
    coalesce((select created_at from auth.users where id = p_uid), now()),
    coalesce(public.billing_limites_desde(), '-infinity'::timestamptz),
    coalesce((select max(l.ended_at) from public.coach_links l where l.student_id = p_uid and l.status = 'encerrado'), '-infinity'::timestamptz)
  ) + interval '30 days';
$$;

-- Interna: plano de aluno valendo agora: 'pro' | 'teste' | 'gratis'.
create or replace function public.aluno_plano(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when public.movo_admin_uid(p_uid) then 'pro'
    when public.plano_efetivo(p_uid, 'aluno') <> 'gratis' then 'pro'
    when exists (select 1 from public.coach_links l
                 where l.student_id = p_uid and l.status in ('ativo', 'pausado')
                   and public.plano_efetivo(l.coach_id, 'treinador') <> 'gratis') then 'pro'
    when now() < public.aluno_trial_fim(p_uid) then 'teste'
    else 'gratis'
  end;
$$;

-- Interna: limites de cada plano. null = sem limite.
--   ia_mes: usos de IA por mês em cada recurso | fichas: fichas de academia | grafico_meses: meses de evolução
--   criar_desafio: pode criar desafio (participar é sempre livre) | alunos: vínculos do treinador
create or replace function public.plano_limites(p_linha text, p_plano text)
returns jsonb
language sql
immutable
as $$
  select case p_linha || ':' || p_plano
    when 'aluno:pro'         then '{"ia_mes": 30, "fichas": null, "grafico_meses": null, "criar_desafio": true}'::jsonb
    when 'aluno:teste'       then '{"ia_mes": 30, "fichas": null, "grafico_meses": null, "criar_desafio": true}'::jsonb
    when 'aluno:gratis'      then '{"ia_mes": 1, "fichas": 2, "grafico_meses": 3, "criar_desafio": false}'::jsonb
    when 'treinador:start'   then '{"ia_mes": 10, "alunos": 10}'::jsonb
    when 'treinador:pro'     then '{"ia_mes": 30, "alunos": 30}'::jsonb
    when 'treinador:studio'  then '{"ia_mes": 30, "alunos": 80}'::jsonb
    when 'treinador:gratis'  then '{"ia_mes": 2, "alunos": 3}'::jsonb
    else '{"ia_mes": 1}'::jsonb
  end;
$$;

-- Cota de IA: pelo plano de aluno (teste/pro/gratis) ou pelo de treinador pago, o que der mais.
create or replace function public.ia_limite_efetivo(p_uid uuid, p_cliente int)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not public.billing_cfg('limites') then p_cliente
    else greatest(
      (public.plano_limites('aluno', public.aluno_plano(p_uid))->>'ia_mes')::int,
      case when public.plano_efetivo(p_uid, 'treinador') <> 'gratis'
           then (public.plano_limites('treinador', public.plano_efetivo(p_uid, 'treinador'))->>'ia_mes')::int else 0 end
    )
  end;
$$;

revoke all on function public.billing_limites_desde() from public, anon, authenticated;
revoke all on function public.aluno_trial_fim(uuid) from public, anon, authenticated;
revoke all on function public.aluno_plano(uuid) from public, anon, authenticated;
revoke all on function public.ia_limite_efetivo(uuid, int) from public, anon, authenticated;

-- O app pergunta o plano da pessoa logada.
create or replace function public.my_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  adm boolean;
  pa text; pt text; pe text; fim timestamptz;
  ra public.assinaturas; rt public.assinaturas;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  adm := public.movo_admin_uid(uid);
  pa := public.aluno_plano(uid);
  pe := public.plano_efetivo(uid, 'aluno');
  pt := public.plano_efetivo(uid, 'treinador');
  fim := public.aluno_trial_fim(uid);
  select * into ra from public.assinaturas where user_id = uid and linha = 'aluno';
  select * into rt from public.assinaturas where user_id = uid and linha = 'treinador';
  return jsonb_build_object(
    'visivel', adm or public.billing_cfg('visivel'),
    'limites', public.billing_cfg('limites'),
    'admin', adm,
    'aluno', jsonb_build_object(
      'plano', pa,
      'cobertura', case when adm then 'admin' when pe <> 'gratis' then 'assinatura' when pa = 'pro' then 'treinador' end,
      'status', ra.status, 'ciclo', ra.ciclo, 'renova_em', ra.renova_em,
      'teste_ate', case when pa = 'teste' then fim else ra.teste_ate end,
      'dias_teste', case when pa = 'teste' then greatest(0, ceil(extract(epoch from (fim - now())) / 86400))::int end,
      'recursos', public.plano_limites('aluno', pa),
      'ia_mes', (public.plano_limites('aluno', pa)->>'ia_mes')::int),
    'treinador', jsonb_build_object(
      'plano', pt, 'status', rt.status, 'ciclo', rt.ciclo, 'teste_ate', rt.teste_ate, 'renova_em', rt.renova_em,
      'alunos_max', (public.plano_limites('treinador', pt)->>'alunos')::int,
      'alunos_usados', (select count(*) from public.coach_links where coach_id = uid and status in ('pendente', 'ativo', 'pausado')))
  );
end;
$$;
revoke all on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;

-- Admin: ao LIGAR os limites, marca o dia (o teste de 30 dias de quem já usa começa aí).
create or replace function public.admin_billing_set(p_chave text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if p_chave not in ('visivel', 'limites') then raise exception 'chave desconhecida'; end if;
  if p_chave = 'limites' and coalesce(p_on, false) and not public.billing_cfg('limites') then
    insert into public.app_config (chave, valor, atualizado_em) values ('billing_limites_desde', to_jsonb(now()::text), now())
      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('billing_' || p_chave, to_jsonb(coalesce(p_on, false)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end;
$$;

-- Criar desafio: só Pro/teste quando os limites valem (participar continua livre).
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
  if public.billing_cfg('limites')
     and coalesce((public.plano_limites('aluno', public.aluno_plano(auth.uid()))->>'criar_desafio')::boolean, false) is not true then
    raise exception 'limite_plano_desafio';
  end if;
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

-- ======================================================================
-- admin_functions_setup.sql
-- ======================================================================
-- Funções de admin: rodam com privilégio elevado (security definer), mas só
-- devolvem dados de verdade se quem chamou for o e-mail admin — pra
-- qualquer outro usuário, o "where" abaixo dá falso pra toda linha e volta
-- vazio. Não é só esconder botão no app: é checado aqui dentro do banco.

-- "ultimo_login" (auth.users.last_sign_in_at) só muda quando a sessão expira
-- e a pessoa precisa logar de novo — pode ficar parado por semanas mesmo com
-- uso diário. "ultimo_acesso"/"acessos_*" vêm de app_opens (1 registro por
-- abertura do app, ver app.js) e são a fonte de verdade de uso real. Mudar
-- as colunas do retorno exige dropar a função antes (create or replace não
-- permite alterar a assinatura de saída).
drop function if exists public.admin_usage_stats();

create function public.admin_usage_stats()
returns table (
  user_id uuid,
  email text,
  cadastrou_em timestamptz,
  ultimo_login timestamptz,
  ultimo_acesso timestamptz,
  ultima_atualizacao timestamptz,
  fez_onboarding boolean,
  conectou_strava boolean,
  acessos_7d bigint,
  acessos_30d bigint,
  dias_com_acesso_7d bigint,
  dias_ativos_7d bigint,
  dias_ativos_30d bigint
)
language sql
security definer
set search_path = public, auth
as $$
  select
    u.id,
    u.email,
    u.created_at,
    u.last_sign_in_at,
    ao.ultimo_acesso,
    ad.updated_at,
    (ad.treinos is not null and jsonb_array_length(ad.treinos) > 0),
    (sc.user_id is not null),
    coalesce(ao.acessos_7d, 0),
    coalesce(ao.acessos_30d, 0),
    coalesce(ao.dias_com_acesso_7d, 0),
    (select count(*) from jsonb_object_keys(coalesce(ad.sessions, '{}'::jsonb)) d
       where d::date >= current_date - interval '7 days'),
    (select count(*) from jsonb_object_keys(coalesce(ad.sessions, '{}'::jsonb)) d
       where d::date >= current_date - interval '30 days')
  from auth.users u
  left join public.app_data ad on ad.user_id = u.id
  left join public.strava_connections sc on sc.user_id = u.id
  left join lateral (
    select
      max(o.opened_at) as ultimo_acesso,
      count(*) filter (where o.opened_at >= now() - interval '7 days') as acessos_7d,
      count(*) filter (where o.opened_at >= now() - interval '30 days') as acessos_30d,
      count(distinct o.opened_at::date) filter (where o.opened_at >= now() - interval '7 days') as dias_com_acesso_7d
    from public.app_opens o
    where o.user_id = u.id
  ) ao on true
  where public.is_movo_admin()
  order by u.created_at desc;
$$;

grant execute on function public.admin_usage_stats() to authenticated;

create or replace function public.admin_client_errors(limit_n int default 50)
returns table (
  created_at timestamptz,
  email text,
  context text,
  message text
)
language sql
security definer
set search_path = public, auth
as $$
  select ce.created_at, u.email, ce.context, ce.message
  from public.client_errors ce
  left join auth.users u on u.id = ce.user_id
  where public.is_movo_admin()
  order by ce.created_at desc
  limit limit_n;
$$;

grant execute on function public.admin_client_errors(int) to authenticated;

-- ======================================================================
-- admin_overview_setup.sql
-- ======================================================================
-- Painel geral de uso (admin): números agregados de todos os usuários — não
-- por pessoa (isso já existe em admin_usage_stats) — pra ver de relance
-- quantos usuários existem, quantos estão ativos e a tendência diária.
-- Mesmo esquema de segurança das outras funções admin: security definer +
-- confere o e-mail de quem chamou (ardurso@gmail.com) antes de devolver
-- qualquer linha; pra qualquer outro usuário, o "where" dá falso e some
-- tudo (nessas duas funções, como não tem "from" de verdade, a query
-- simplesmente não devolve nenhuma linha — não dá erro, só fica vazio).

drop function if exists public.admin_overview_stats();

create function public.admin_overview_stats()
returns table (
  total_usuarios bigint,
  ativos_hoje bigint,
  ativos_7d bigint,
  ativos_30d bigint,
  novos_7d bigint,
  novos_30d bigint,
  completaram_onboarding bigint,
  conectaram_strava bigint,
  tamanho_banco_mb numeric
)
language sql
security definer
set search_path = public, auth
as $$
  -- "Hoje" precisa ser calculado no fuso de Brasília, não em UTC (padrão do
  -- banco) — do contrário, à noite (horário de Brasília), o UTC já virou o
  -- dia seguinte e quem acessou mais cedo some da contagem de "hoje".
  -- date_trunc(...) AT TIME ZONE 'America/Sao_Paulo' é o idioma padrão do
  -- Postgres pra achar "meia-noite de hoje, num fuso específico" como um
  -- instante de verdade (timestamptz), comparável com opened_at.
  select
    (select count(*) from auth.users),
    (select count(distinct user_id) from public.app_opens where opened_at >= (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')),
    (select count(distinct user_id) from public.app_opens where opened_at >= now() - interval '7 days'),
    (select count(distinct user_id) from public.app_opens where opened_at >= now() - interval '30 days'),
    (select count(*) from auth.users where created_at >= now() - interval '7 days'),
    (select count(*) from auth.users where created_at >= now() - interval '30 days'),
    (select count(*) from public.app_data where treinos is not null and jsonb_array_length(treinos) > 0),
    (select count(distinct user_id) from public.strava_connections),
    -- Tamanho do banco todo (não só uma tabela) — plano gratuito do Supabase
    -- tem teto de 500 MB; isso é o que mais cedo vira limite, bem antes do
    -- teto de 50 mil usuários ativos/mês.
    (select round(pg_database_size(current_database()) / 1024.0 / 1024.0, 1))
  where public.is_movo_admin();
$$;

grant execute on function public.admin_overview_stats() to authenticated;

-- "Usuários ativos" por dia nos últimos N dias (default 14), pra desenhar o
-- gráfico de tendência — inclui dias com zero acesso (generate_series),
-- senão um dia parado simplesmente some do gráfico em vez de aparecer como
-- uma barra zerada. Mesmo cuidado de fuso horário do admin_overview_stats:
-- "dia" é calculado em America/Sao_Paulo, não em UTC — senão a barra de
-- "hoje" (e o corte entre um dia e outro) fica até 3h deslocada.
drop function if exists public.admin_daily_active(int);

create function public.admin_daily_active(dias int default 14)
returns table (
  dia date,
  usuarios_ativos bigint
)
language sql
security definer
set search_path = public, auth
as $$
  select s.d::date, coalesce(count(distinct o.user_id), 0)
  from generate_series(
    (now() at time zone 'America/Sao_Paulo')::date - (dias - 1),
    (now() at time zone 'America/Sao_Paulo')::date,
    interval '1 day'
  ) as s(d)
  left join public.app_opens o on (o.opened_at at time zone 'America/Sao_Paulo')::date = s.d::date
  where public.is_movo_admin()
  group by s.d
  order by s.d;
$$;

grant execute on function public.admin_daily_active(int) to authenticated;

-- ======================================================================
-- admin_login_stats.sql
-- ======================================================================
-- Logins e saídas por usuário nos últimos N dias (default 7), a partir dos
-- eventos login_codigo / login_link / logout de app_events. Serve pra ver
-- quem está precisando logar de novo toda hora (muitos logins, poucas
-- saídas = a sessão caiu sozinha). Mesmo esquema de segurança das outras
-- funções admin: security definer + confere o e-mail de quem chamou.
drop function if exists public.admin_login_stats(int);

create function public.admin_login_stats(dias int default 7)
returns table (email text, logins bigint, logouts bigint, ultimo_login timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select u.email::text,
         count(*) filter (where e.name in ('login_codigo', 'login_link')) as logins,
         count(*) filter (where e.name = 'logout') as logouts,
         max(e.created_at) filter (where e.name in ('login_codigo', 'login_link')) as ultimo_login
  from public.app_events e
  join auth.users u on u.id = e.user_id
  where e.name in ('login_codigo', 'login_link', 'logout')
    and e.created_at >= now() - make_interval(days => dias)
    and public.is_movo_admin()
  group by u.email
  order by logins desc;
$$;

grant execute on function public.admin_login_stats(int) to authenticated;

-- ======================================================================
-- admin_plan_usage.sql
-- ======================================================================
-- Painel de admin: consumo da geração de plano de corrida com IA.
-- Uma linha por pessoa que gerou planos (mês atual no horário de São Paulo + total desde sempre).
-- Só o admin recebe linhas. Seguro rodar de novo. Requer plan_generations_setup.sql.

drop function if exists public.admin_plan_usage();

create function public.admin_plan_usage()
returns table (email text, no_mes bigint, total bigint, ultima timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select u.email::text,
         count(*) filter (where g.created_at >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') as no_mes,
         count(*) as total,
         max(g.created_at) as ultima
  from public.plan_generations g
  join auth.users u on u.id = g.user_id
  where public.is_movo_admin()
  group by u.email
  order by no_mes desc, max(g.created_at) desc
  limit 50;
$$;

revoke all on function public.admin_plan_usage() from public, anon;
grant execute on function public.admin_plan_usage() to authenticated;

-- ======================================================================
-- admin_shared_races.sql
-- ======================================================================
-- Painel de admin: moderar provas cadastradas pela comunidade (shared_races).
-- Lista as provas (mais recentes primeiro) com quem cadastrou, e permite esconder/mostrar.
-- Só o admin recebe linhas / consegue alterar. Seguro rodar de novo. Requer races_cloud_setup.sql.

drop function if exists public.admin_shared_races();

create function public.admin_shared_races()
returns table (id bigint, nome text, data_inicio date, cidade text, uf text, modalidade text, oculta boolean, criada_por_email text, created_at timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select r.id, r.nome, r.data_inicio, r.cidade, r.uf, r.modalidade, r.oculta, u.email::text, r.created_at
  from public.shared_races r
  left join auth.users u on u.id = r.criada_por
  where public.is_movo_admin()
  order by r.created_at desc
  limit 100;
$$;

create or replace function public.admin_set_race_oculta(p_id bigint, p_oculta boolean)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then
    raise exception 'not allowed';
  end if;
  update public.shared_races set oculta = p_oculta where id = p_id;
  return found;
end;
$$;

revoke all on function public.admin_shared_races() from public, anon;
revoke all on function public.admin_set_race_oculta(bigint, boolean) from public, anon;
grant execute on function public.admin_shared_races() to authenticated;
grant execute on function public.admin_set_race_oculta(bigint, boolean) to authenticated;

-- ======================================================================
-- admin_versoes.sql
-- ======================================================================
-- Painel admin: quantas pessoas abriram cada versão do app (última abertura de cada pessoa nos últimos N dias).
-- Requer app_opens_setup.sql e a função is_movo_admin() (catalogo_banco.sql). Seguro rodar de novo.

alter table public.app_opens add column if not exists versao text;

create or replace function public.admin_versoes(p_dias integer default 7)
returns table(versao text, pessoas integer, abriu_por_ultimo timestamptz)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return query
  with ult as (
    select distinct on (o.user_id) o.user_id, coalesce(o.versao, 'antes da v164') as v, o.opened_at
    from app_opens o
    where o.opened_at >= now() - make_interval(days => greatest(1, least(p_dias, 90)))
    order by o.user_id, o.opened_at desc)
  select v, count(*)::int, max(opened_at) from ult group by v order by max(opened_at) desc;
end $$;
revoke all on function public.admin_versoes(integer) from public, anon;
grant execute on function public.admin_versoes(integer) to authenticated;

-- ======================================================================
-- admin_metricas.sql
-- ======================================================================
-- Painel de métricas (movoapp.com.br/admin/): origem do acesso + consultas agregadas, uma por aba.
-- Só o admin (is_movo_admin) executa; cada função devolve poucos números já somados (nada de listas grandes).
-- Requer app_opens_setup.sql, app_events, lp_events e is_movo_admin() (catalogo_banco.sql). Seguro rodar de novo.

alter table public.app_opens add column if not exists host text;        -- endereço de onde o app foi aberto
alter table public.app_opens add column if not exists instalado boolean; -- aberto como app instalado (PWA)

-- Dia no fuso de São Paulo
create or replace function public._m_dia(t timestamptz) returns date
language sql immutable as $$ select (t at time zone 'America/Sao_Paulo')::date $$;

-- Site de origem de cada abertura: pelo host quando existe; antes disso, pela versão (<= v174 = antigo, >= v175 = novo)
create or replace function public._m_site(p_host text, p_versao text) returns text
language sql immutable as $$
  select case
    when p_host is not null then case when p_host like '%github.io' then 'antigo' else 'novo' end
    when p_versao ~ '^v[0-9]+$' and substring(p_versao from 2)::int >= 175 then 'novo'
    else 'antigo' end $$;

-- Aba "Visão geral"
create or replace function public.admin_m_geral() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'contas', (select count(*) from auth.users),
    'novas_7d', (select count(*) from auth.users where public._m_dia(created_at) >= hoje - 6),
    'novas_hoje', (select count(*) from auth.users where public._m_dia(created_at) = hoje),
    'dau', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) = hoje),
    'wau', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - 6),
    'mau', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - 29),
    'abriram_algum_dia', (select count(distinct user_id) from app_opens),
    'com_treino', (select count(distinct user_id) from app_events where name in ('treino_concluido','primeiro_registro','corrida_registrada_manual')),
    'instalado_7d', (select count(distinct user_id) from app_opens where instalado is true and public._m_dia(opened_at) >= hoje - 6),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', g::date::text, 'pessoas', coalesce(x.p,0), 'aberturas', coalesce(x.a,0), 'novas', coalesce(n.c,0)) order by g), '[]'::jsonb)
      from generate_series(hoje - 29, hoje, interval '1 day') gs(g)
      left join (select public._m_dia(opened_at) d, count(distinct user_id) p, count(*) a from app_opens group by 1) x on x.d = g::date
      left join (select public._m_dia(created_at) d, count(*) c from auth.users group by 1) n on n.d = g::date)
  ) into r;
  return r;
end $$;

-- Aba "Retenção": por semana de cadastro, quantos voltaram (D1 = dia seguinte; D7 = entre o dia 7 e 13; D30 = dia 30 em diante)
create or replace function public.admin_m_retencao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with u as (select id, public._m_dia(created_at) sd from auth.users),
  f as (
    select u.id, u.sd,
      date_trunc('week', u.sd)::date semana,
      (hoje >= u.sd + 1) el1, (hoje >= u.sd + 7) el7, (hoje >= u.sd + 30) el30,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) = u.sd + 1) d1,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) between u.sd + 7 and u.sd + 13) d7,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) >= u.sd + 30) d30
    from u)
  select jsonb_build_object(
    'semanas', coalesce((select jsonb_agg(to_jsonb(w) order by w.semana desc) from (
        select semana::text semana, count(*) cadastros,
          count(*) filter (where el1) el1, count(*) filter (where el1 and d1) d1,
          count(*) filter (where el7) el7, count(*) filter (where el7 and d7) d7,
          count(*) filter (where el30) el30, count(*) filter (where el30 and d30) d30
        from f group by semana) w), '[]'::jsonb),
    'total', (select jsonb_build_object('cadastros', count(*),
        'el1', count(*) filter (where el1), 'd1', count(*) filter (where el1 and d1),
        'el7', count(*) filter (where el7), 'd7', count(*) filter (where el7 and d7),
        'el30', count(*) filter (where el30), 'd30', count(*) filter (where el30 and d30)) from f)
  ) into r;
  return r;
end $$;

-- Aba "Funil": quantas pessoas chegaram em cada etapa (eventos só existem desde 05/10/2026)
create or replace function public.admin_m_funil() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_array(
    jsonb_build_object('etapa','Criaram conta','n',(select count(*) from auth.users)),
    jsonb_build_object('etapa','Abriram o app','n',(select count(distinct user_id) from app_opens)),
    jsonb_build_object('etapa','Aceitaram os termos','n',(select count(distinct user_id) from app_events where name='aceite_registrado')),
    jsonb_build_object('etapa','Começaram o onboarding','n',(select count(distinct user_id) from app_events where name='onboarding_iniciado')),
    jsonb_build_object('etapa','Concluíram o onboarding','n',(select count(distinct user_id) from app_events where name='onboarding_concluido')),
    jsonb_build_object('etapa','Registraram o 1º treino','n',(select count(distinct user_id) from app_events where name in ('treino_concluido','primeiro_registro','corrida_registrada_manual'))),
    jsonb_build_object('etapa','Treinaram em 2 dias ou mais','n',(select count(*) from (select user_id from app_events where name='treino_concluido' group by user_id having count(distinct public._m_dia(created_at)) >= 2) q)),
    jsonb_build_object('etapa','Voltaram 7+ dias após o cadastro','n',(select count(distinct u.id) from auth.users u join app_opens o on o.user_id = u.id and public._m_dia(o.opened_at) >= public._m_dia(u.created_at) + 7))
  ) into r;
  return r;
end $$;

-- Aba "Funcionalidades": pessoas e vezes por evento no período, e quantas dessas pessoas foram ativas nos últimos 7 dias
create or replace function public.admin_m_funcoes(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 365)); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'ativos_7d', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - 6),
    'ativos_periodo', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) >= hoje - (d - 1)),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v, 'pessoas_7d', p7, 'ultima', ult::text) order by p desc, v desc)
      from (select name, count(distinct user_id) p, count(*) v,
              count(distinct user_id) filter (where public._m_dia(created_at) >= hoje - 6) p7,
              max(public._m_dia(created_at)) ult
            from app_events where public._m_dia(created_at) >= hoje - (d - 1) group by name) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Aba "Convites e landing"
create or replace function public.admin_m_convites(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare d int := greatest(1, least(p_dias, 365)); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v) order by name)
      from (select name, count(distinct user_id) p, count(*) v from app_events
            where name in ('convite_whatsapp','desafio_criado','desafio_cartao_compartilhado','desafio_entrou','desafio_aplauso')
              and public._m_dia(created_at) >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'landing', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc)
      from (select name, sum(n)::int n from lp_events where day >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'origens', coalesce((select jsonb_agg(jsonb_build_object('src', src, 'n', n) order by n desc)
      from (select coalesce(nullif(src,''),'(direto)') src, sum(n)::int n from lp_events
            where name in ('visita','page_view','view') and day >= public._m_dia(now()) - (d - 1) group by 1 limit 12) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Aba "Domínio e versões": quem ainda acessa o site antigo
create or replace function public.admin_m_dominio(p_dias integer default 14) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 60)); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'host_desde', (select min(opened_at) from app_opens where host is not null),
    'serie', coalesce((select jsonb_agg(jsonb_build_object('dia', dia::text, 'site', site, 'pessoas', p) order by dia, site)
      from (select public._m_dia(opened_at) dia, public._m_site(host, versao) site, count(distinct user_id) p
            from app_opens where public._m_dia(opened_at) >= hoje - (d - 1) group by 1,2) q), '[]'::jsonb),
    'hoje_antigo', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) = hoje and public._m_site(host, versao) = 'antigo'),
    'hoje_novo', (select count(distinct user_id) from app_opens where public._m_dia(opened_at) = hoje and public._m_site(host, versao) = 'novo'),
    'banner', (select jsonb_build_object('pessoas', count(distinct user_id), 'vezes', count(*)) from app_events where name = 'dominio_novo_aberto'),
    'versoes', coalesce((select jsonb_agg(jsonb_build_object('versao', v, 'pessoas', n) order by n desc)
      from (select coalesce(versao,'antes da v164') v, count(*) n from (
              select distinct on (user_id) user_id, versao from app_opens
              where public._m_dia(opened_at) >= hoje - 6 order by user_id, opened_at desc) z group by 1) q), '[]'::jsonb),
    'ainda_antigo', coalesce((select jsonb_agg(jsonb_build_object('email', email, 'ultima', ult, 'versao', versao, 'dias', dias) order by ult desc)
      from (select u.email, x.ult, x.versao, x.dias from (
              select distinct on (user_id) user_id, opened_at ult, versao from app_opens
              where public._m_dia(opened_at) >= hoje - 6 order by user_id, opened_at desc) l
            join auth.users u on u.id = l.user_id
            join lateral (select l.ult, l.versao, (select count(distinct public._m_dia(o.opened_at)) from app_opens o where o.user_id = l.user_id and public._m_dia(o.opened_at) >= hoje - 6) dias) x on true
            where public._m_site((select o2.host from app_opens o2 where o2.user_id = l.user_id order by o2.opened_at desc limit 1), l.versao) = 'antigo') q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_m_geral()','admin_m_retencao()','admin_m_funil()','admin_m_funcoes(integer)','admin_m_convites(integer)','admin_m_dominio(integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- admin_metricas_v2.sql
-- ======================================================================
-- Painel de métricas, rodada 1: "treino" com uma definição só, exclui você e contas de teste, janelas fechadas,
-- funil só com contas novas (eventos existem desde 05/10/2026) e card "pronto para redirecionar?".
-- Requer admin_metricas.sql (funções _m_dia, _m_site). Seguro rodar de novo.

-- Contas que não entram nas métricas (você e testes). Para incluir outra: edite a lista em app_config 'metricas_excluir'.
insert into public.app_config(chave, valor) values ('metricas_excluir', '["ardurso@gmail.com"]'::jsonb)
on conflict (chave) do nothing;

create or replace function public._m_excl() returns uuid[]
language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(u.id), '{}'::uuid[]) from auth.users u
  where lower(u.email) in (select lower(x) from jsonb_array_elements_text(coalesce((select valor from public.app_config where chave = 'metricas_excluir'), '[]'::jsonb)) x) $$;

-- "Treinou" = qualquer um destes eventos (academia, 1º registro, corrida manual)
create or replace function public._m_treino() returns text[]
language sql immutable as $$ select array['treino_concluido','primeiro_registro','corrida_registrada_manual'] $$;

-- Visão geral
create or replace function public.admin_m_geral() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with a as (select user_id, public._m_dia(opened_at) dia from app_opens where user_id <> all(ex)),
  v as (select e.user_id, public._m_dia(e.created_at) dia from app_events e where e.name = any(public._m_treino()) and e.user_id <> all(ex)),
  d as (select dia, count(distinct user_id) p from a group by dia)
  select jsonb_build_object(
    'excluidas', coalesce(array_length(ex,1),0),
    'contas', (select count(*) from auth.users where id <> all(ex)),
    'novas_7d', (select count(*) from auth.users where id <> all(ex) and public._m_dia(created_at) >= hoje - 6),
    'novas_hoje', (select count(*) from auth.users where id <> all(ex) and public._m_dia(created_at) = hoje),
    'dau', (select count(distinct user_id) from a where dia = hoje),
    'dau_ontem', (select count(distinct user_id) from a where dia = hoje - 1),
    'dau_media_7d', (select coalesce(round(avg(p)::numeric, 1), 0) from d where dia between hoje - 7 and hoje - 1),
    'wau', (select count(distinct user_id) from a where dia >= hoje - 6),
    'mau', (select count(distinct user_id) from a where dia >= hoje - 29),
    'abriram_algum_dia', (select count(distinct user_id) from a),
    'treinaram_7d', (select count(distinct user_id) from v where dia >= hoje - 6),
    'treinaram_30d', (select count(distinct user_id) from v where dia >= hoje - 29),
    'dois_dias_7d', (select count(*) from (select user_id from v where dia >= hoje - 6 group by user_id having count(distinct dia) >= 2) q),
    'com_treino', (select count(distinct user_id) from v),
    'instalado_7d', (select count(distinct user_id) from app_opens where user_id <> all(ex) and instalado is true and public._m_dia(opened_at) >= hoje - 6),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', g::date::text, 'pessoas', coalesce(x.p,0), 'treinaram', coalesce(t.p,0), 'novas', coalesce(n.c,0)) order by g), '[]'::jsonb)
      from generate_series(hoje - 29, hoje, interval '1 day') gs(g)
      left join d x on x.dia = g::date
      left join (select dia, count(distinct user_id) p from v group by dia) t on t.dia = g::date
      left join (select public._m_dia(created_at) dia, count(*) c from auth.users where id <> all(ex) group by 1) n on n.dia = g::date)
  ) into r;
  return r;
end $$;

-- Retenção: D1 = dia seguinte; D7 = dias 7 a 13; D30 = dias 28 a 34 (janela fechada). Só conta quem já completou a janela.
create or replace function public.admin_m_retencao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with u as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex)),
  f as (
    select u.id, u.sd, date_trunc('week', u.sd)::date semana,
      (hoje >= u.sd + 1) el1, (hoje >= u.sd + 13) el7, (hoje >= u.sd + 34) el30,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) = u.sd + 1) d1,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) between u.sd + 7 and u.sd + 13) d7,
      exists (select 1 from app_opens o where o.user_id = u.id and public._m_dia(o.opened_at) between u.sd + 28 and u.sd + 34) d30
    from u)
  select jsonb_build_object(
    'semanas', coalesce((select jsonb_agg(to_jsonb(w) order by w.semana desc) from (
        select semana::text semana, count(*) cadastros,
          count(*) filter (where el1) el1, count(*) filter (where el1 and d1) d1,
          count(*) filter (where el7) el7, count(*) filter (where el7 and d7) d7,
          count(*) filter (where el30) el30, count(*) filter (where el30 and d30) d30
        from f group by semana) w), '[]'::jsonb),
    'total', (select jsonb_build_object('cadastros', count(*),
        'el1', count(*) filter (where el1), 'd1', count(*) filter (where el1 and d1),
        'el7', count(*) filter (where el7), 'd7', count(*) filter (where el7 and d7),
        'el30', count(*) filter (where el30), 'd30', count(*) filter (where el30 and d30)) from f)
  ) into r;
  return r;
end $$;

-- Funil: só contas criadas a partir de 05/10/2026, quando os eventos começaram), todas as etapas sobre o mesmo grupo
create or replace function public.admin_m_funil() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); p_desde date := date '2026-10-05'; r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex) and public._m_dia(created_at) >= p_desde),
  ev as (select distinct e.user_id, e.name from app_events e join c on c.id = e.user_id),
  tr as (select e.user_id, count(distinct public._m_dia(e.created_at)) dias from app_events e join c on c.id = e.user_id where e.name = any(public._m_treino()) group by e.user_id)
  select jsonb_build_object('desde', p_desde::text, 'itens', jsonb_build_array(
    jsonb_build_object('etapa','Criaram conta','n',(select count(*) from c)),
    jsonb_build_object('etapa','Abriram o app','n',(select count(distinct o.user_id) from app_opens o join c on c.id = o.user_id)),
    jsonb_build_object('etapa','Aceitaram os termos','n',(select count(*) from ev where name='aceite_registrado')),
    jsonb_build_object('etapa','Começaram o onboarding','n',(select count(*) from ev where name='onboarding_iniciado')),
    jsonb_build_object('etapa','Concluíram o onboarding','n',(select count(*) from ev where name='onboarding_concluido')),
    jsonb_build_object('etapa','Registraram o 1º treino','n',(select count(*) from tr)),
    jsonb_build_object('etapa','Treinaram em 2 dias ou mais','n',(select count(*) from tr where dias >= 2)),
    jsonb_build_object('etapa','Abriram de novo após 7+ dias (só quem tem 7+ dias de conta)',
      'n',(select count(distinct c.id) from c join app_opens o on o.user_id = c.id and public._m_dia(o.opened_at) >= c.sd + 7 where hoje >= c.sd + 7),
      'base',(select count(*) from c where hoje >= c.sd + 7))
  )) into r;
  return r;
end $$;

-- Uso por funcionalidade: devolve os dois denominadores (quem abriu e quem treinou no período)
create or replace function public.admin_m_funcoes(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 365)); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'ativos_7d', (select count(distinct user_id) from app_opens where user_id <> all(ex) and public._m_dia(opened_at) >= hoje - 6),
    'ativos_periodo', (select count(distinct user_id) from app_opens where user_id <> all(ex) and public._m_dia(opened_at) >= hoje - (d - 1)),
    'treinaram_periodo', (select count(distinct user_id) from app_events where user_id <> all(ex) and name = any(public._m_treino()) and public._m_dia(created_at) >= hoje - (d - 1)),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v, 'pessoas_7d', p7, 'ultima', ult::text) order by p desc, v desc)
      from (select name, count(distinct user_id) p, count(*) v,
              count(distinct user_id) filter (where public._m_dia(created_at) >= hoje - 6) p7,
              max(public._m_dia(created_at)) ult
            from app_events where user_id <> all(ex) and public._m_dia(created_at) >= hoje - (d - 1) group by name) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Convites e landing
create or replace function public.admin_m_convites(p_dias integer default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare d int := greatest(1, least(p_dias, 365)); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'pessoas', p, 'vezes', v) order by name)
      from (select name, count(distinct user_id) p, count(*) v from app_events
            where user_id <> all(ex)
              and name in ('convite_whatsapp','desafio_criado','desafio_cartao_compartilhado','desafio_entrou','desafio_aplauso')
              and public._m_dia(created_at) >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'landing', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc)
      from (select name, sum(n)::int n from lp_events where day >= public._m_dia(now()) - (d - 1) group by name) q), '[]'::jsonb),
    'origens', coalesce((select jsonb_agg(jsonb_build_object('src', src, 'n', n) order by n desc)
      from (select coalesce(nullif(src,''),'(direto)') src, sum(n)::int n from lp_events
            where name = 'view' and day >= public._m_dia(now()) - (d - 1) group by 1 limit 12) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Domínio: gráfico por dia e "pronto para redirecionar?"
-- Pronto = ninguém que abriu o endereço antigo nos últimos 30 dias deixou de abrir o novo (nenhuma abertura no novo, nunca).
create or replace function public.admin_m_dominio(p_dias integer default 14) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); d int := greatest(1, least(p_dias, 60)); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with o as (select user_id, opened_at, versao, host, public._m_dia(opened_at) dia, public._m_site(host, versao) site
             from app_opens where user_id <> all(ex)),
  ult as (select distinct on (user_id) user_id, opened_at, versao, site from o where dia >= hoje - 29 order by user_id, opened_at desc),
  pend as (select user_id from o where site = 'antigo' and dia >= hoje - 29
           except select user_id from o where site = 'novo'),
  lista as (
    select u.email, l.opened_at ult, l.versao, l.site,
      (l.versao is null or (l.versao ~ '^v[0-9]+$' and substring(l.versao from 2)::int < 163)) sem_aviso,
      (select count(distinct dia) from o where o.user_id = l.user_id and o.dia >= hoje - 13) dias,
      (l.user_id in (select user_id from pend)) sem_novo
    from ult l join auth.users u on u.id = l.user_id where l.site = 'antigo' or l.user_id in (select user_id from pend))
  select jsonb_build_object(
    'host_desde', (select min(opened_at) from o where host is not null),
    'serie', coalesce((select jsonb_agg(jsonb_build_object('dia', dia::text, 'site', site, 'pessoas', p) order by dia, site)
      from (select dia, site, count(distinct user_id) p from o where dia >= hoje - (d - 1) group by 1,2) q), '[]'::jsonb),
    'hoje_antigo', (select count(distinct user_id) from o where dia = hoje and site = 'antigo'),
    'hoje_novo', (select count(distinct user_id) from o where dia = hoje and site = 'novo'),
    'ativos_14d', (select count(*) from ult where public._m_dia(opened_at) >= hoje - 13),
    'antigo_14d', (select count(*) from lista where public._m_dia(ult) >= hoje - 13),
    'sem_novo_30d', (select count(*) from pend),
    'sem_aviso', (select count(*) from lista where sem_aviso),
    'pronto', (select count(*) = 0 from pend),
    'banner', (select jsonb_build_object('pessoas', count(distinct user_id), 'vezes', count(*)) from app_events where name = 'dominio_novo_aberto' and user_id <> all(ex)),
    'versoes', coalesce((select jsonb_agg(jsonb_build_object('versao', v, 'pessoas', n) order by n desc)
      from (select coalesce(versao,'antes da v164') v, count(*) n from ult where public._m_dia(opened_at) >= hoje - 13 group by 1) q), '[]'::jsonb),
    'ainda_antigo', coalesce((select jsonb_agg(jsonb_build_object('email', email, 'ultima', ult, 'versao', versao, 'dias', dias, 'sem_aviso', sem_aviso, 'sem_novo', sem_novo) order by ult desc) from lista), '[]'::jsonb)
  ) into r;
  return r;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_m_geral()','admin_m_retencao()','admin_m_funil()','admin_m_funcoes(integer)','admin_m_convites(integer)','admin_m_dominio(integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- A lista de contas excluídas não deve ser chamada de fora; só as funções admin_m_* (security definer) a usam.
revoke all on function public._m_excl() from public, anon, authenticated;

-- ======================================================================
-- admin_metricas_v3.sql
-- ======================================================================
-- Painel de métricas, rodada 2: propriedades nos eventos, origem do cadastro, ativação/"aha", canal → 1º treino
-- e "quem usou voltou mais?". Requer admin_metricas.sql e admin_metricas_v2.sql. Seguro rodar de novo.

-- 1) Eventos com propriedades (ex.: treino_registrado { tipo, origem })
alter table public.app_events add column if not exists props jsonb;

-- 2) Origem do cadastro: uma linha por conta, gravada pelo próprio app (só a conta dona consegue inserir; ninguém lê de fora)
create table if not exists public.user_origem (
  user_id uuid primary key references auth.users(id) on delete cascade,
  src text,        -- utm_source do link (ex.: lp, lp-treinador)
  pos text,        -- posição do botão na landing
  convite text,    -- desafio | treinador | prof (quando entrou por convite)
  host text,
  criado_em timestamptz not null default now());
alter table public.user_origem enable row level security;
grant insert on public.user_origem to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_origem' and policyname = 'user_origem_insert_own') then
    create policy user_origem_insert_own on public.user_origem for insert to authenticated with check (auth.uid() = user_id);
  end if;
end $$;

-- 3) "Treinou" passa a incluir o evento único treino_registrado
create or replace function public._m_treino() returns text[]
language sql immutable as $$ select array['treino_registrado','treino_concluido','primeiro_registro','corrida_registrada_manual'] $$;

-- 4) Ativação e "aha moment", por semana de cadastro (só contas criadas desde 05/10/2026, quando os eventos começaram)
--    ativação: 1º treino em até 7 dias da criação da conta (só contas com 7+ dias)
--    aha: 2º dia de treino em até 7 dias depois do 1º (só quem treinou e já passaram 7 dias desde o 1º)
create or replace function public.admin_m_ativacao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex) and public._m_dia(created_at) >= date '2026-10-05'),
  t as (select e.user_id, public._m_dia(e.created_at) dia from app_events e join c on c.id = e.user_id where e.name = any(public._m_treino()) group by 1, 2),
  prim as (select c.id, c.sd, min(t.dia) primeiro from c join t on t.user_id = c.id group by c.id, c.sd),
  seg as (select p.id, min(t.dia) segundo from prim p join t on t.user_id = p.id and t.dia > p.primeiro group by p.id),
  f as (select c.id, date_trunc('week', c.sd)::date semana,
          (hoje >= c.sd + 7) el_a,
          (p.primeiro is not null and p.primeiro <= c.sd + 7) a1,
          (p.primeiro is not null and hoje >= p.primeiro + 7) el_b,
          (p.primeiro is not null and s.segundo is not null and s.segundo <= p.primeiro + 7) a2
        from c left join prim p on p.id = c.id left join seg s on s.id = c.id)
  select jsonb_build_object(
    'semanas', coalesce((select jsonb_agg(to_jsonb(w) order by w.semana desc) from (
        select semana::text semana, count(*) contas,
          count(*) filter (where el_a) el_a, count(*) filter (where el_a and a1) a1,
          count(*) filter (where el_b) el_b, count(*) filter (where el_b and a2) a2
        from f group by semana) w), '[]'::jsonb),
    'total', (select jsonb_build_object('contas', count(*),
        'el_a', count(*) filter (where el_a), 'a1', count(*) filter (where el_a and a1),
        'el_b', count(*) filter (where el_b), 'a2', count(*) filter (where el_b and a2)) from f)
  ) into r;
  return r;
end $$;

-- 5) Canal → 1º treino (origem gravada a partir da v177; contas anteriores aparecem como "sem registro")
create or replace function public.admin_m_canais() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (
    select u.id, public._m_dia(u.created_at) sd,
      case when o.user_id is null then 'sem registro'
           when o.convite is not null then 'convite: ' || o.convite
           when o.src is not null then o.src
           else 'direto' end canal
    from auth.users u left join user_origem o on o.user_id = u.id
    where u.id <> all(ex) and public._m_dia(u.created_at) >= date '2026-10-05'),
  t as (select e.user_id, min(public._m_dia(e.created_at)) primeiro from app_events e join c on c.id = e.user_id where e.name = any(public._m_treino()) group by 1),
  f as (select c.canal, c.id, (hoje >= c.sd + 7) el, (t.primeiro is not null) treinou, (t.primeiro is not null and t.primeiro <= c.sd + 7) a1
        from c left join t on t.user_id = c.id)
  select coalesce(jsonb_agg(to_jsonb(w) order by w.contas desc), '[]'::jsonb) into r from (
    select canal, count(*) contas, count(*) filter (where treinou) treinaram,
      count(*) filter (where el) el, count(*) filter (where el and a1) a1
    from f group by canal) w;
  return r;
end $$;

-- 6) Quem usou a funcionalidade voltou mais? Por evento: das pessoas que usaram (com 7+ dias desde o 1º uso), quantas abriram o app
--    nos 7 dias seguintes; comparado com quem não usou (com 7+ dias de conta). Só sinal de direção, nunca causa.
create or replace function public.admin_m_usoretorno() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare hoje date := public._m_dia(now()); ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with c as (select id, public._m_dia(created_at) sd from auth.users where id <> all(ex) and public._m_dia(created_at) >= date '2026-10-05'),
  o as (select distinct user_id, public._m_dia(opened_at) dia from app_opens),
  fu as (select e.user_id, e.name, min(public._m_dia(e.created_at)) fdia from app_events e join c on c.id = e.user_id
         where e.name !~ '^(aceite_|login_|onboarding_|onb_|tela_|logout|dominio_|estado_vazio_|modo_|semana_card_|catalogo_)' group by 1, 2),
  nm as (select name from fu group by name having count(*) >= 2),
  t as (
    select nm.name, fu.user_id, fu.fdia, true usou from nm join fu using (name) where fu.fdia + 7 <= hoje
    union all
    select nm.name, c.id, c.sd, false from nm cross join c
      where c.sd + 7 <= hoje and not exists (select 1 from fu where fu.user_id = c.id and fu.name = nm.name)),
  z as (select t.*, exists (select 1 from o where o.user_id = t.user_id and o.dia between t.fdia + 1 and t.fdia + 7) ret from t)
  select coalesce(jsonb_agg(to_jsonb(w) order by w.usou_n desc, w.name), '[]'::jsonb) into r from (
    select name,
      count(*) filter (where usou) usou_n, count(*) filter (where usou and ret) usou_ret,
      count(*) filter (where not usou) nao_n, count(*) filter (where not usou and ret) nao_ret
    from z group by name having count(*) filter (where usou) >= 2) w;
  return r;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_m_ativacao()','admin_m_canais()','admin_m_usoretorno()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- monitoramento.sql
-- ======================================================================
-- Monitoramento: resumo de saúde do app (erros, IA, banco) para o painel admin e para o alerta por e-mail.
-- Seguro rodar de novo. Requer client_errors_setup.sql, ai_usage_cost.sql, ai_kill_switch.sql e app_opens_setup.sql.

create or replace function public.saude_resumo()
returns jsonb
language sql
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'erros_30min', (select count(*) from public.client_errors where created_at > now() - interval '30 minutes'),
    'erros_1h', (select count(*) from public.client_errors where created_at > now() - interval '1 hour'),
    'erros_24h', (select count(*) from public.client_errors where created_at > now() - interval '24 hours'),
    'erros_24h_antes', (select count(*) from public.client_errors where created_at <= now() - interval '24 hours' and created_at > now() - interval '48 hours'),
    'erros_top', coalesce((select jsonb_agg(t) from (
        select context, count(*) as n, max(left(message, 140)) as exemplo
          from public.client_errors where created_at > now() - interval '24 hours'
         group by context order by count(*) desc limit 5) t), '[]'::jsonb),
    'ia_falhas_1h', (select count(*) from public.ai_usage_log where created_at > now() - interval '1 hour' and not ok),
    'ia_total_1h', (select count(*) from public.ai_usage_log where created_at > now() - interval '1 hour'),
    'ia_falhas_24h', (select count(*) from public.ai_usage_log where created_at > now() - interval '24 hours' and not ok),
    'ia_total_24h', (select count(*) from public.ai_usage_log where created_at > now() - interval '24 hours'),
    'ia_hoje_usd', coalesce((select sum(custo_usd) from public.ai_usage_log
        where created_at >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'), 0),
    'ia_teto_usd', coalesce((select (valor)::text::numeric from public.app_config where chave = 'ai_teto_diario_usd'), 5),
    'ia_ativa', coalesce((select (valor)::text::boolean from public.app_config where chave = 'ai_ativa'), true),
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
    'ativos_24h', (select count(distinct user_id) from public.app_opens where opened_at > now() - interval '24 hours')
  );
$$;
revoke all on function public.saude_resumo() from public, anon, authenticated;
grant execute on function public.saude_resumo() to service_role;

create or replace function public.admin_saude()
returns jsonb
language sql
security definer
set search_path = public, auth
as $$
  select public.saude_resumo()
  where public.is_movo_admin();
$$;
revoke all on function public.admin_saude() from public, anon;
grant execute on function public.admin_saude() to authenticated;

-- Agendamento: a cada 15 minutos o banco chama a função alerta-saude (que confere erros/IA/banco e manda e-mail).
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'alerta_cron_secret') then
    perform vault.create_secret(encode(gen_random_bytes(24), 'hex'), 'alerta_cron_secret');
  end if;
end $$;

create or replace function public.alerta_segredo_ok(p text)
returns boolean
language sql
security definer
set search_path = public, vault
as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'alerta_cron_secret' and decrypted_secret = p);
$$;
revoke all on function public.alerta_segredo_ok(text) from public, anon, authenticated;
grant execute on function public.alerta_segredo_ok(text) to service_role;

select cron.unschedule('alerta-saude') where exists (select 1 from cron.job where jobname = 'alerta-saude');
select cron.schedule('alerta-saude', '*/15 * * * *', $job$
  select net.http_post(
    url := 'https://wgdhjkebfvcmgokxscvb.supabase.co/functions/v1/alerta-saude',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'alerta_cron_secret')),
    body := '{}'::jsonb
  );
$job$);

-- ======================================================================
-- lp_events.sql
-- ======================================================================
-- Contadores anônimos de visita da landing page (movoapp.com.br): só dia + evento + posição + origem, sem cookie, sem IP.
-- A página chama a função lp_event com a chave pública; a tabela não tem política (ninguém lê de fora; só o painel/SQL).
-- Para ver: select day, name, pos, src, n from public.lp_events order by day desc, n desc;
-- Seguro rodar de novo.
create table if not exists public.lp_events (
  day date not null default current_date,
  name text not null,
  pos text not null default '',
  src text not null default '',
  n bigint not null default 0,
  primary key (day, name, pos, src)
);
alter table public.lp_events enable row level security;

create or replace function public.lp_event(p_name text, p_pos text default '', p_src text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_name not in ('view','cta_open_app','video_play','chapter','click_email','install_guide') then return; end if;
  if p_pos not in ('','nav','hero','video','vantagens','desafio','treinador','faq','final','sticky','install','ficha','treinar','desafios','corrida','treinadores','como-funciona','videos','recursos','instalar','perguntas') then p_pos := ''; end if;
  if p_src not in ('','whatsapp','instagram','indicacao','direto','facebook','tiktok','google','youtube','linkedin','email','lp') then p_src := 'outro'; end if;
  insert into public.lp_events(day,name,pos,src,n) values (current_date,p_name,p_pos,p_src,1)
  on conflict (day,name,pos,src) do update set n = public.lp_events.n + 1;
end $$;
revoke all on function public.lp_event(text,text,text) from public;
grant execute on function public.lp_event(text,text,text) to anon, authenticated;

-- ======================================================================
-- account_data_rights.sql
-- ======================================================================
-- Direitos do titular (LGPD): exportar os próprios dados e excluir a conta.
-- As duas funções rodam com privilégio elevado, mas só mexem em dados de quem chamou (auth.uid()).

create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  mail text;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select email into mail from auth.users where id = uid;
  return jsonb_build_object(
    'exportado_em', now(),
    'conta', jsonb_build_object('id', uid, 'email', mail),
    'dados_do_app', (select to_jsonb(a) - 'user_id' from public.app_data a where a.user_id = uid),
    'provas_marcadas', coalesce((select jsonb_agg(to_jsonb(e) - 'user_id') from public.race_entries e where e.user_id = uid), '[]'::jsonb),
    'privacidade_provas', (select to_jsonb(p) - 'user_id' from public.race_privacy p where p.user_id = uid),
    'feedbacks', coalesce((select jsonb_agg(to_jsonb(f) - 'user_id') from public.user_feedback f where f.user_id = uid), '[]'::jsonb),
    'desafios', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'inicio', c.start_date, 'semanas', c.weeks, 'criador', c.owner_id = uid))
                          from public.challenges c join public.challenge_members m on m.challenge_id = c.id where m.user_id = uid), '[]'::jsonb),
    'checkins_desafios', coalesce((select jsonb_agg(to_jsonb(k) - 'user_id') from public.challenge_checkins k where k.user_id = uid), '[]'::jsonb),
    'relatorios_compartilhados_por_mim', coalesce((select jsonb_agg(jsonb_build_object('para', r.viewer_email, 'criado_em', r.created_at, 'revogado_em', r.revoked_at))
                                                    from public.report_shares r where r.owner_user_id = uid), '[]'::jsonb),
    'amigos_total', (select count(*) from public.friendships f where f.user_a = uid or f.user_b = uid),
    'strava', jsonb_build_object('conectado', exists(select 1 from public.strava_connections s where s.user_id = uid),
                                 'ultima_sincronizacao', (select s.last_sync_at from public.strava_connections s where s.user_id = uid)),
    'geracoes_com_ia', coalesce((select jsonb_agg(jsonb_build_object('tipo', g.kind, 'quando', g.created_at)) from public.plan_generations g where g.user_id = uid), '[]'::jsonb),
    'aceites_politica_termos', coalesce((select jsonb_agg(jsonb_build_object('versao', c.versao, 'aceito_em', c.aceito_em)) from public.user_consents c where c.user_id = uid), '[]'::jsonb),
    'acessos_ao_app_total', (select count(*) from public.app_opens o where o.user_id = uid),
    'telefone', (select c.telefone from public.user_contact c where c.user_id = uid),
    'foto_de_perfil', exists(select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = uid::text || '/a.jpg'),
    'treinador', jsonb_build_object(
      'sou_treinador', coalesce((select to_jsonb(p) - 'user_id' from public.coach_profiles p where p.user_id = uid), 'null'::jsonb),
      'vinculos', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'papel', case when l.coach_id = uid then 'treinador' else 'aluno' end,
                                   'status', l.status, 'permissoes', l.permissions, 'criado_em', l.created_at, 'aceito_em', l.accepted_at, 'encerrado_em', l.ended_at))
                            from public.coach_links l where l.coach_id = uid or l.student_id = uid), '[]'::jsonb),
      'treinos_recebidos', coalesce((select jsonb_agg(jsonb_build_object('tipo', a.tipo, 'versao', a.versao, 'status', a.status, 'mensagem', a.mensagem, 'enviado_em', a.created_at, 'conteudo', a.payload))
                            from public.coach_assignments a join public.coach_links l on l.id = a.link_id where l.student_id = uid), '[]'::jsonb),
      'treinos_enviados', coalesce((select jsonb_agg(jsonb_build_object('tipo', a.tipo, 'versao', a.versao, 'status', a.status, 'mensagem', a.mensagem, 'enviado_em', a.created_at))
                            from public.coach_assignments a join public.coach_links l on l.id = a.link_id where l.coach_id = uid), '[]'::jsonb),
      'comentarios_meus', coalesce((select jsonb_agg(jsonb_build_object('data', n.date, 'texto', n.texto, 'criado_em', n.created_at)) from public.coach_notes n where n.author_id = uid), '[]'::jsonb),
      'comentarios_para_mim', coalesce((select jsonb_agg(jsonb_build_object('data', n.date, 'texto', n.texto, 'criado_em', n.created_at))
                            from public.coach_notes n join public.coach_links l on l.id = n.link_id where l.student_id = uid and n.author_id <> uid), '[]'::jsonb),
      'agenda', jsonb_build_object(
        'compromissos', coalesce((select jsonb_agg(jsonb_build_object('tipo', g.tipo, 'titulo', g.titulo, 'hora', g.hora_inicio, 'duracao_min', g.duracao_min, 'dias_semana', g.dias_semana, 'data', g.data_unica, 'inicio_em', g.inicio_em, 'fim_em', g.fim_em)) from public.coach_agenda_itens g where g.coach_id = uid), '[]'::jsonb),
        'alunos_da_agenda', coalesce((select jsonb_agg(jsonb_build_object('nome', a.nome, 'email', a.email, 'telefone', a.telefone, 'pacotes', coalesce((select jsonb_agg(jsonb_build_object('total_aulas', k.total, 'validade_dias', k.validade_dias, 'falta_desconta', k.falta_desconta, 'inicio_em', k.inicio_em, 'encerrado_em', k.encerrado_em, 'obs', k.obs)) from public.coach_agenda_pacotes k where k.pessoa_id = a.id), '[]'::jsonb))) from public.coach_agenda_pessoas a where a.coach_id = uid), '[]'::jsonb),
        'janela_de_trabalho', (select jsonb_build_object('janela', c.janela, 'duracao_padrao_min', c.duracao_padrao) from public.coach_agenda_config c where c.coach_id = uid)),
      'modelos', coalesce((select jsonb_agg(jsonb_build_object('nome', t.nome, 'conteudo', t.payload, 'criado_em', t.created_at)) from public.coach_templates t where t.coach_id = uid), '[]'::jsonb),
      'convites_que_fiz_ao_treinador', coalesce((select jsonb_agg(jsonb_build_object('status', i.status, 'permissoes', i.permissions, 'criado_em', i.created_at, 'usado_em', i.used_at))
                            from public.coach_student_invites i where i.student_id = uid), '[]'::jsonb),
      'consentimentos', coalesce((select jsonb_agg(jsonb_build_object('acao', au.acao, 'quando', au.quando, 'detalhe', au.meta))
                            from public.coach_audit au left join public.coach_links l on l.id = au.link_id
                            where (l.student_id = uid or (au.ator = uid and au.link_id is null)) and au.acao in ('consentimento', 'permissoes', 'convite_aluno_criado', 'termos_treinador')), '[]'::jsonb)
    )
  );
end;
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  mail text;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select lower(email) into mail from auth.users where id = uid;

  -- desafios que a pessoa criou e que têm outros membros passam para o membro mais antigo
  update public.challenges c
     set owner_id = (select m.user_id from public.challenge_members m
                      where m.challenge_id = c.id and m.user_id <> uid order by m.joined_at limit 1)
   where c.owner_id = uid
     and exists (select 1 from public.challenge_members m where m.challenge_id = c.id and m.user_id <> uid);

  -- tabelas cujo vínculo é "set null" ou por e-mail: apaga explicitamente
  delete from public.client_errors where user_id = uid;
  delete from public.user_feedback where user_id = uid;
  delete from public.friend_requests where lower(to_email) = mail;
  delete from public.report_shares where lower(viewer_email) = mail;

  -- o resto (dados do app, check-ins, amizades, Strava, etc.) cai em cascata
  delete from auth.users where id = uid;
end;
$$;

revoke execute on function public.export_my_data() from public, anon;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.export_my_data() to authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- ======================================================================
-- challenge_acertos.sql
-- ======================================================================
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
    'stakes', c.stakes,
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

-- ======================================================================
-- challenge_acertos_saida.sql
-- ======================================================================
-- Prêmios P1 (parte 2): sair/excluir desafio respeitando o livro-caixa. Rodar depois de challenge_acertos.sql.
-- Sair do desafio: fecha o que já passou antes (quem sai paga o que deve).
create or replace function public.leave_challenge(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.challenges where id = p_id;
  if v_owner is null then return; end if;
  if v_owner = auth.uid() then raise exception 'quem criou não pode sair: exclua o desafio'; end if;
  perform public._challenge_close(p_id);
  delete from public.challenge_checkins where challenge_id = p_id and user_id = auth.uid();
  delete from public.challenge_together where challenge_id = p_id and (from_user = auth.uid() or to_user = auth.uid());
  delete from public.challenge_members where challenge_id = p_id and user_id = auth.uid();
end;
$$;

-- Excluir: não pode se houver acerto em aberto.
create or replace function public.delete_challenge(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._challenge_close(p_id);
  if exists (
    select 1 from public.challenge_ledger l
    left join public.challenge_acerto_status s on s.ledger_id = l.id
    where l.challenge_id = p_id and s.received_at is null and s.forgiven_at is null
  ) then raise exception 'ainda há acertos em aberto: quite ou perdoe antes de excluir'; end if;
  delete from public.challenges where id = p_id and owner_id = auth.uid();
end;
$$;

-- ======================================================================
-- challenge_formatos.sql
-- ======================================================================
-- Prêmios P1 (formatos): o criador escolhe, por fase (semana / final), o modo:
--   'ultimo' = só quem fica em último paga valor (dividido entre quem ficou em 1º)
--   'pote'   = todos entram com "valor"; o pote é dividido por colocação (divisao: [100], [70,30] ou [50,30,20])
-- Padrões retrocompatíveis: semana = 'ultimo', final = 'pote' com [100] (cada um paga ao campeão).
-- Soma zero por construção, para qualquer tamanho de grupo. Empate divide a(s) fatia(s) das posições empatadas.
-- Sem teto de valores nem de pessoas. Divisão em vários prêmios exige grupo mínimo na data de início.
-- Idempotente. Depende de challenge_acertos.sql.

create or replace function public._challenge_stakes_check() returns trigger language plpgsql as $$
declare
  vs numeric := coalesce(nullif(new.stakes->>'semana_valor', '')::numeric, 0);
  vf numeric := coalesce(nullif(new.stakes->>'final_valor', '')::numeric, 0);
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  d jsonb; soma int; ph text;
  chaves text[] := array['semana_valor','final_valor','semana_modo','final_modo','semana_divisao','final_divisao'];
begin
  -- sem teto de negócio (o Movo não lida com o dinheiro); só um limite técnico contra estouro de número
  if vs < 0 or vs > 100000 then raise exception 'valor da semana inválido'; end if;
  if vf < 0 or vf > 100000 then raise exception 'valor do final inválido'; end if;
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
  ms text; mf text; ds int[]; df int[]; n0 int;
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

  -- Divisão em mais de um prêmio só vale se o grupo, na data de início, tinha gente suficiente
  -- (2 prêmios = 4 pessoas, 3 prêmios = 5). Senão, vira "tudo pro 1º".
  select count(*) into n0 from public.challenge_members m
   where m.challenge_id = p_id and ((m.joined_at at time zone 'America/Sao_Paulo')::date <= ch.start_date or m.user_id = ch.owner_id);
  if array_length(ds, 1) > 1 and n0 < array_length(ds, 1) + 2 then ds := array[100]; end if;
  if array_length(df, 1) > 1 and n0 < array_length(df, 1) + 2 then df := array[100]; end if;

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

revoke all on function public._challenge_settle(uuid, text, int, text, int, int[], jsonb) from public, anon, authenticated;
revoke all on function public._challenge_stakes_check() from public, anon, authenticated;
revoke all on function public._challenge_close(uuid) from public, anon, authenticated;

-- Sem limite de pessoas: entrar é só entrar (volta ao comportamento original).
create or replace function public.join_challenge(p_code text)
returns uuid
language plpgsql security definer set search_path = public as $$
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
revoke all on function public.join_challenge(text) from public, anon;
grant execute on function public.join_challenge(text) to authenticated;

-- ======================================================================
-- indicacoes.sql
-- ======================================================================
-- "Traga seu amigo pro Movo": cada pessoa tem um código de indicação; o link é
-- https://movoapp.com.br/convite/?amigo=CODIGO. Quem cria conta por esse link fica com user_origem.ref_code = CODIGO.
-- A pessoa vê só números (entraram / já treinaram), nunca nomes. Idempotente.

alter table public.user_origem add column if not exists ref_code text;
create index if not exists user_origem_ref_idx on public.user_origem (ref_code) where ref_code is not null;

create table if not exists public.user_referral (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique,
  criado_em timestamptz not null default now()
);
alter table public.user_referral enable row level security;
revoke all on public.user_referral from public, anon, authenticated;

create or replace function public.my_referral()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_code text;
  v_try int := 0;
begin
  if me is null then raise exception 'not authenticated'; end if;
  select code into v_code from public.user_referral where user_id = me;
  if v_code is null then
    loop
      v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 7));
      begin
        insert into public.user_referral (user_id, code) values (me, v_code);
        exit;
      exception when unique_violation then
        select code into v_code from public.user_referral where user_id = me;
        exit when v_code is not null;
        v_try := v_try + 1;
        if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
      end;
    end loop;
  end if;
  return jsonb_build_object(
    'code', v_code,
    'entraram', (select count(*) from public.user_origem o where o.ref_code = v_code and o.user_id <> me),
    'treinaram', (select count(*) from public.user_origem o where o.ref_code = v_code and o.user_id <> me
                  and exists (select 1 from public.app_events e where e.user_id = o.user_id and e.name = any (public._m_treino())))
  );
end;
$$;
revoke all on function public.my_referral() from public, anon;
grant execute on function public.my_referral() to authenticated;

-- ======================================================================
-- challenge_convites.sql
-- ======================================================================
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

-- ======================================================================
-- challenge_convites_email.sql
-- ======================================================================
-- Convite por e-mail: (a) aviso ao amigo convidado pela lista; (b) convite a quem ainda não tem conta.
-- O envio é feito pela edge function `convidar-email` (Resend); aqui ficam as regras e o limite de abuso.
-- Limite: 15 e-mails por pessoa por dia; o mesmo endereço não recebe o mesmo desafio duas vezes em 7 dias.

alter table public.challenge_invites add column if not exists emailed_at timestamptz;

create table if not exists public.convite_email_log (
  id bigint generated always as identity primary key,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_email text not null,
  challenge_id uuid references public.challenges(id) on delete set null,
  kind text not null check (kind in ('amigo', 'novo')),
  created_at timestamptz not null default now()
);
create index if not exists convite_email_log_from_idx on public.convite_email_log (from_user, created_at desc);
alter table public.convite_email_log enable row level security;
revoke all on public.convite_email_log from public, anon, authenticated;

create or replace function public.convite_email_preparar(p_id uuid, p_user_ids uuid[] default null, p_email text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_ch public.challenges;
  v_from text;
  v_my_email text;
  v_email text;
  v_targets jsonb := '[]'::jsonb;
  r record;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if not public.is_challenge_member(p_id) then raise exception 'você não participa deste desafio'; end if;
  if (select count(*) from public.convite_email_log where from_user = me and created_at > now() - interval '24 hours') >= 15 then
    raise exception 'limite diário de convites por e-mail atingido';
  end if;
  select * into v_ch from public.challenges where id = p_id;
  select coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)), u.email
    into v_from, v_my_email
    from auth.users u left join public.app_data a on a.user_id = u.id where u.id = me;

  if p_email is not null then
    v_email := lower(trim(p_email));
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'e-mail inválido'; end if;
    if v_email = lower(v_my_email) then raise exception 'esse é o seu e-mail'; end if;
    if exists (select 1 from public.challenge_members m join auth.users u on u.id = m.user_id where m.challenge_id = p_id and lower(u.email) = v_email) then
      raise exception 'essa pessoa já está no desafio';
    end if;
    if exists (select 1 from public.convite_email_log where lower(to_email) = v_email and challenge_id = p_id and created_at > now() - interval '7 days') then
      raise exception 'esse e-mail já foi convidado para este desafio';
    end if;
    insert into public.convite_email_log (from_user, to_email, challenge_id, kind) values (me, v_email, p_id, 'novo');
    v_targets := v_targets || jsonb_build_array(jsonb_build_object('email', v_email));
  end if;

  if p_user_ids is not null then
    for r in
      update public.challenge_invites i set emailed_at = now()
       where i.challenge_id = p_id and i.from_user = me and i.status = 'pending' and i.emailed_at is null and i.to_user = any (p_user_ids)
       returning i.to_user
    loop
      select email into v_email from auth.users where id = r.to_user;
      if v_email is not null then
        insert into public.convite_email_log (from_user, to_email, challenge_id, kind) values (me, lower(v_email), p_id, 'amigo');
        v_targets := v_targets || jsonb_build_array(jsonb_build_object('email', v_email));
      end if;
    end loop;
  end if;

  return jsonb_build_object('nome', v_ch.nome, 'code', v_ch.invite_code, 'from_nome', v_from, 'targets', v_targets);
end;
$$;
revoke all on function public.convite_email_preparar(uuid, uuid[], text) from public, anon;
grant execute on function public.convite_email_preparar(uuid, uuid[], text) to authenticated;

-- ======================================================================
-- coach_pedido_aluno.sql
-- ======================================================================
-- Aluno pede a um treinador que já está no Movo (busca por nome ou e-mail).
-- Reaproveita coach_student_invites: o convite ganha um destinatário (para_coach). Só ele consegue ver e aceitar.
-- Idempotente. Requer coach_setup_v2.sql.
alter table public.coach_student_invites add column if not exists para_coach uuid references auth.users(id) on delete cascade;
alter table public.coach_student_invites add column if not exists recusado_em timestamptz;
create index if not exists coach_student_invites_para_idx on public.coach_student_invites (para_coach, status);

-- O convite por link (sem destinatário) continua sendo um só por aluno; os pedidos diretos não mexem nele.
create or replace function public.coach_student_invite_create(p_permissions jsonb default null, p_maior boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_perms jsonb; v_try int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not coalesce(p_maior, false) then raise exception 'precisa confirmar que tem 18 anos ou mais'; end if;
  if exists (select 1 from public.coach_links x where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')) then
    raise exception 'ja_tem_treinador';
  end if;
  v_perms := public.coach_clean_perms(coalesce(p_permissions, '{}'::jsonb));
  update public.coach_student_invites set status = 'cancelado' where student_id = auth.uid() and status = 'aberto' and para_coach is null;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_student_invites where invite_code = v_code)
          and not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_student_invites (student_id, invite_code, permissions) values (auth.uid(), v_code, v_perms);
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (null, auth.uid(), 'convite_aluno_criado', jsonb_build_object('texto_versao', 'v1', 'permissions', v_perms, 'maior_de_18', true));
  perform public.coach_log_event('convite_aluno_criado');
  return jsonb_build_object('invite_code', v_code, 'permissions', v_perms, 'created_at', now());
end;
$$;

create or replace function public.coach_student_invite_open()
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_student_invites;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.coach_student_invites
   where student_id = auth.uid() and status = 'aberto' and para_coach is null and created_at > now() - interval '14 days'
   order by created_at desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('invite_code', i.invite_code, 'permissions', i.permissions, 'created_at', i.created_at);
end;
$$;

create or replace function public.coach_student_invite_cancel()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_student_invites set status = 'cancelado' where student_id = auth.uid() and status = 'aberto' and para_coach is null;
end;
$$;

-- Prévia: pedido com destinatário só é visível para o destinatário (e para o próprio aluno).
create or replace function public.coach_student_invite_preview(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_student_invites; n text; v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.coach_student_invites where invite_code = upper(trim(p_code));
  if not found then return null; end if;
  if i.para_coach is not null and i.para_coach <> auth.uid() and i.student_id <> auth.uid() then return null; end if;
  select nullif(display_name, '') into n from public.app_data where user_id = i.student_id;
  v_status := case when i.status = 'aberto' and i.created_at < now() - interval '14 days' then 'expirado' else i.status end;
  return jsonb_build_object(
    'aluno_nome', coalesce(n, 'Um aluno'), 'aluno_uid', i.student_id, 'status', v_status,
    'eh_o_proprio', i.student_id = auth.uid(),
    'meu_cadastro', (select status from public.coach_profiles where user_id = auth.uid()),
    'permissions', i.permissions);
end;
$$;

create or replace function public.coach_student_invite_accept(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_student_invites; v_link uuid; v_code text; v_try int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.coach_student_invites where invite_code = upper(trim(p_code)) for update;
  if not found then raise exception 'convite inválido'; end if;
  if i.student_id = auth.uid() then raise exception 'você não pode ser treinador de si mesmo'; end if;
  if i.para_coach is not null and i.para_coach <> auth.uid() then raise exception 'convite inválido'; end if;
  if i.status <> 'aberto' then raise exception 'convite não está mais disponível'; end if;
  if i.created_at < now() - interval '14 days' then raise exception 'convite expirado'; end if;
  if not exists (select 1 from public.coach_profiles where user_id = auth.uid() and status in ('em_analise', 'ativo')) then
    raise exception 'cadastro_pendente';
  end if;
  if exists (select 1 from public.coach_links x where x.student_id = i.student_id and x.status in ('ativo', 'pausado')) then
    raise exception 'o aluno já tem treinador';
  end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_links where invite_code = v_code)
          and not exists (select 1 from public.coach_student_invites where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_links (coach_id, student_id, status, invite_code, permissions, accepted_at)
  values (auth.uid(), i.student_id, 'ativo', v_code, i.permissions, now())
  returning id into v_link;
  update public.coach_student_invites set status = 'usado', coach_id = auth.uid(), used_at = now() where id = i.id;
  -- os outros pedidos abertos desse aluno perdem o sentido
  update public.coach_student_invites set status = 'cancelado' where student_id = i.student_id and status = 'aberto' and id <> i.id;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (v_link, i.student_id, 'consentimento', jsonb_build_object('texto_versao', 'v1', 'permissions', i.permissions, 'maior_de_18', true,
          'origem', case when i.para_coach is null then 'convite_do_aluno' else 'pedido_do_aluno' end));
  perform public.coach_log_event('convite_aluno_aceito');
  return jsonb_build_object('link_id', v_link);
end;
$$;

-- Aluno: busca treinadores ativos por nome (3+ letras) ou e-mail exato. Devolve só o que o treinador mostra no perfil.
create or replace function public.coach_buscar(p_q text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q text := lower(trim(coalesce(p_q, '')));
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if char_length(q) < 3 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('coach_id', p.user_id, 'nome', p.nome_exibicao, 'bio', p.bio, 'cref', p.cref) order by p.nome_exibicao)
    from (
      select p.* from public.coach_profiles p
      where p.status = 'ativo' and p.user_id <> auth.uid()
        and (lower(p.nome_exibicao) like '%' || replace(replace(q, '%', ''), '_', '') || '%'
             or (position('@' in q) > 0 and exists (select 1 from auth.users u where u.id = p.user_id and lower(u.email) = q)))
      order by p.nome_exibicao limit 8
    ) p
  ), '[]'::jsonb);
end;
$$;

-- Aluno: pede a um treinador específico.
create or replace function public.coach_pedir(p_coach uuid, p_permissions jsonb default null, p_maior boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_perms jsonb; v_try int := 0; v_nome text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not coalesce(p_maior, false) then raise exception 'precisa confirmar que tem 18 anos ou mais'; end if;
  if p_coach = auth.uid() then raise exception 'operação não permitida'; end if;
  select nome_exibicao into v_nome from public.coach_profiles where user_id = p_coach and status = 'ativo';
  if not found then raise exception 'treinador não encontrado'; end if;
  if exists (select 1 from public.coach_links x where x.student_id = auth.uid() and x.status in ('ativo', 'pausado')) then
    raise exception 'ja_tem_treinador';
  end if;
  if exists (select 1 from public.coach_student_invites where student_id = auth.uid() and para_coach = p_coach
             and ((status = 'aberto' and created_at > now() - interval '14 days') or recusado_em > now() - interval '7 days')) then
    raise exception 'você já fez um pedido a este treinador';
  end if;
  if (select count(*) from public.coach_student_invites where student_id = auth.uid() and para_coach is not null
      and status = 'aberto' and created_at > now() - interval '14 days') >= 3 then
    raise exception 'limite de 3 pedidos em aberto';
  end if;
  v_perms := public.coach_clean_perms(coalesce(p_permissions, '{}'::jsonb));
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.coach_student_invites where invite_code = v_code)
          and not exists (select 1 from public.coach_links where invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
  end loop;
  insert into public.coach_student_invites (student_id, invite_code, permissions, para_coach) values (auth.uid(), v_code, v_perms, p_coach);
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (null, auth.uid(), 'pedido_aluno_criado', jsonb_build_object('texto_versao', 'v1', 'permissions', v_perms, 'maior_de_18', true, 'coach', p_coach));
  perform public.coach_log_event('pedido_aluno_criado');
  return jsonb_build_object('invite_code', v_code, 'coach_nome', v_nome);
end;
$$;

-- Aluno: pedidos diretos (abertos nos últimos 14 dias e recusados nos últimos 7).
create or replace function public.coach_meus_pedidos()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('invite_code', i.invite_code, 'coach_nome', coalesce(p.nome_exibicao, 'Treinador'),
             'status', case when i.recusado_em is not null then 'recusado' else 'aberto' end, 'criado_em', i.created_at) order by i.created_at desc)
    from public.coach_student_invites i left join public.coach_profiles p on p.user_id = i.para_coach
    where i.student_id = auth.uid() and i.para_coach is not null
      and ((i.status = 'aberto' and i.created_at > now() - interval '14 days') or i.recusado_em > now() - interval '7 days')
  ), '[]'::jsonb);
end;
$$;

create or replace function public.coach_pedido_cancelar(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_student_invites set status = 'cancelado'
   where student_id = auth.uid() and invite_code = upper(trim(p_code)) and para_coach is not null and status = 'aberto';
end;
$$;

-- Treinador: pedidos que recebeu.
create or replace function public.coach_pedidos_recebidos()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  return coalesce((
    select jsonb_agg(jsonb_build_object('invite_code', i.invite_code, 'aluno_uid', i.student_id,
             'aluno_nome', coalesce(nullif(a.display_name, ''), 'Um aluno'), 'permissions', i.permissions, 'criado_em', i.created_at) order by i.created_at desc)
    from public.coach_student_invites i left join public.app_data a on a.user_id = i.student_id
    where i.para_coach = auth.uid() and i.status = 'aberto' and i.recusado_em is null and i.created_at > now() - interval '14 days'
  ), '[]'::jsonb);
end;
$$;

-- Treinador: recusa (o aluno vê "recusado" por 7 dias; o motivo não é pedido).
create or replace function public.coach_pedido_recusar(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_student_invites set status = 'cancelado', recusado_em = now()
   where invite_code = upper(trim(p_code)) and para_coach = auth.uid() and status = 'aberto';
end;
$$;

grant execute on function public.coach_buscar(text), public.coach_pedir(uuid, jsonb, boolean), public.coach_meus_pedidos(),
  public.coach_pedido_cancelar(text), public.coach_pedidos_recebidos(), public.coach_pedido_recusar(text) to authenticated;

-- ======================================================================
-- avisos_email.sql
-- ======================================================================
-- Avisos por e-mail (edge function `avisar-email`): (a) pedido do aluno a um treinador; (b) relatório liberado para alguém.
-- Só avisa quem já tem conta no Movo (nunca manda e-mail a endereço solto). Limite: 15 por pessoa por dia; o mesmo aviso não repete em 7 dias.
create table if not exists public.aviso_email_log (
  id bigint generated always as identity primary key,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid references auth.users(id) on delete set null,
  tipo text not null check (tipo in ('pedido_treinador', 'relatorio')),
  ref text not null,
  created_at timestamptz not null default now()
);
create index if not exists aviso_email_log_from_idx on public.aviso_email_log (from_user, created_at desc);
alter table public.aviso_email_log enable row level security;
revoke all on public.aviso_email_log from public, anon, authenticated;

create or replace function public.aviso_email_preparar(p_tipo text, p_ref text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_from text; v_to uuid; v_email text; v_inv public.coach_student_invites; v_sh public.report_shares;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if p_tipo not in ('pedido_treinador', 'relatorio') then raise exception 'tipo inválido'; end if;
  if (select count(*) from public.aviso_email_log where from_user = me and created_at > now() - interval '24 hours') >= 15 then
    raise exception 'limite diário de avisos por e-mail atingido';
  end if;
  if exists (select 1 from public.aviso_email_log where from_user = me and tipo = p_tipo and ref = p_ref and created_at > now() - interval '7 days') then
    raise exception 'aviso já enviado';
  end if;
  select coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)) into v_from
    from auth.users u left join public.app_data a on a.user_id = u.id where u.id = me;

  if p_tipo = 'pedido_treinador' then
    select * into v_inv from public.coach_student_invites
     where invite_code = upper(trim(p_ref)) and student_id = me and para_coach is not null and status = 'aberto';
    if not found then raise exception 'pedido não encontrado'; end if;
    v_to := v_inv.para_coach;
  else
    select * into v_sh from public.report_shares where id = nullif(p_ref, '')::bigint and owner_user_id = me and revoked_at is null;
    if not found then raise exception 'compartilhamento não encontrado'; end if;
    select id into v_to from auth.users where lower(email) = lower(v_sh.viewer_email) limit 1;
    if v_to is null then raise exception 'essa pessoa ainda não tem conta no Movo'; end if;
  end if;
  select email into v_email from auth.users where id = v_to;
  if v_email is null then raise exception 'destinatário sem e-mail'; end if;
  insert into public.aviso_email_log (from_user, to_user, tipo, ref) values (me, v_to, p_tipo, p_ref);
  return jsonb_build_object('tipo', p_tipo, 'from_nome', v_from, 'to_email', v_email);
end;
$$;
revoke all on function public.aviso_email_preparar(text, text) from public, anon;
grant execute on function public.aviso_email_preparar(text, text) to authenticated;

-- ======================================================================
-- admin_m_contas.sql
-- ======================================================================
-- Painel de métricas (movoapp.com.br/admin), aba "Contas": todas as contas, com cadastro e último acesso.
-- Só passa quem é admin (is_movo_admin). Requer admin_metricas_v2.sql (_m_excl, _m_treino) e admin_metricas_v3.sql (user_origem).
create or replace function public.admin_m_contas() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select coalesce(jsonb_agg(x order by x.cadastro desc), '[]'::jsonb) into r
  from (
    select
      u.id as id,
      nullif(trim(a.display_name), '') as nome,
      u.email as email,
      u.created_at as cadastro,
      o.ultimo as ultimo_acesso,
      u.last_sign_in_at as ultimo_login,
      coalesce(o.n30, 0) as aberturas_30d,
      exists (select 1 from public.app_events e where e.user_id = u.id and e.name = any (public._m_treino())) as treinou,
      coalesce(nullif(og.convite, ''), nullif(og.src, '')) as origem,
      (u.id = any (public._m_excl())) as teste
    from auth.users u
    left join public.app_data a on a.user_id = u.id
    left join public.user_origem og on og.user_id = u.id
    left join lateral (
      select max(p.opened_at) as ultimo, count(*) filter (where p.opened_at >= now() - interval '30 days') as n30
      from public.app_opens p where p.user_id = u.id
    ) o on true
  ) x;
  return r;
end $$;
revoke all on function public.admin_m_contas() from public, anon;
grant execute on function public.admin_m_contas() to authenticated;

-- ======================================================================
-- user_feedback_relatos.sql
-- ======================================================================
-- Relatos de problema com contexto técnico (v200).
-- O botão "Reportar problema" (menu, barra de erro e tela de erro do app) grava em
-- user_feedback com tipo 'problema', a origem do relato e um jsonb com o contexto:
-- versão, aparelho, aba, últimos erros e telas, e o stack quando a tela quebrou.
-- O agente de revisão (tarefa agendada do projeto) lê os relatos sem revisão e
-- grava o diagnóstico em `revisao`/`revisado_em`.

alter table public.user_feedback add column if not exists origem text not null default 'manual';
alter table public.user_feedback add column if not exists contexto jsonb;
alter table public.user_feedback add column if not exists revisao text;
alter table public.user_feedback add column if not exists revisado_em timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_feedback_origem_chk') then
    alter table public.user_feedback add constraint user_feedback_origem_chk
      check (origem in ('manual', 'erro', 'tela_quebrou'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'user_feedback_contexto_tam_chk') then
    alter table public.user_feedback add constraint user_feedback_contexto_tam_chk
      check (contexto is null or pg_column_size(contexto) <= 32000);
  end if;
end $$;

-- quem envia não escreve a revisão (só o agente/admin, por fora do RLS)
create or replace function public.user_feedback_saneia()
returns trigger language plpgsql as $$
begin
  new.revisao := null;
  new.revisado_em := null;
  return new;
end;
$$;

create or replace trigger user_feedback_saneia_trg before insert on public.user_feedback
  for each row execute function public.user_feedback_saneia();

-- fila do agente: relatos de problema ainda sem revisão
create index if not exists user_feedback_sem_revisao_idx
  on public.user_feedback (created_at) where tipo = 'problema' and revisado_em is null;

-- aba Admin do app (Suporte): contexto e revisão dos relatos
create or replace function public.admin_feedback_contexto(p_ids bigint[])
returns table (id bigint, origem text, contexto jsonb, revisao text, revisado_em timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select f.id, f.origem, f.contexto, f.revisao, f.revisado_em
  from public.user_feedback f
  where f.id = any(p_ids)
    and public.is_movo_admin();
$$;

grant execute on function public.admin_feedback_contexto(bigint[]) to authenticated;

-- ======================================================================
-- relatos_prints.sql
-- ======================================================================
-- Prints no "Fale com a gente" (v203, qualquer categoria): até 3 imagens por mensagem, reduzidas no aparelho
-- (lado maior 1280px, JPEG). Bucket PRIVADO "relatos", pasta = user_id. Só o dono grava/lê/apaga
-- a própria pasta; o admin (is_movo_admin) lê tudo e vê pelo painel de métricas com URL assinada.
-- Seguro rodar de novo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('relatos', 'relatos', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

-- Sem "drop policy" (o conector do Supabase cancela comandos destrutivos): cria só se não existir.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'relatos_insert_own') then
    create policy relatos_insert_own on storage.objects for insert to authenticated
      with check (bucket_id = 'relatos' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'relatos_select_own_ou_admin') then
    create policy relatos_select_own_ou_admin on storage.objects for select to authenticated
      using (bucket_id = 'relatos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_movo_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'relatos_delete_own') then
    create policy relatos_delete_own on storage.objects for delete to authenticated
      using (bucket_id = 'relatos' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

alter table public.user_feedback add column if not exists prints text[];
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_feedback_prints_chk') then
    alter table public.user_feedback add constraint user_feedback_prints_chk
      check (prints is null or cardinality(prints) <= 3);
  end if;
end $$;

-- ======================================================================
-- client_errors_revisao.sql
-- ======================================================================
-- Revisão dos erros automáticos (client_errors), pedido do Andre em 19/10/2026.
-- O Claude marca no banco o que já revisou (revisado_em + revisao); o painel de métricas
-- (aba Mensagens) mostra por padrão só os erros ainda não revisados, com filtro "Todos".
-- Erro novo de um contexto já revisado volta a aparecer (a marcação é por linha, não por contexto).
alter table public.client_errors add column if not exists revisado_em timestamptz;
alter table public.client_errors add column if not exists revisao text;
create index if not exists client_errors_nao_revisados_idx on public.client_errors (created_at) where revisado_em is null;

-- Para marcar (rodar pelo conector, como admin do banco):
--   update public.client_errors set revisado_em = now(), revisao = '<diagnóstico curto>'
--   where context = '<contexto>' and revisado_em is null;

-- ======================================================================
-- admin_m_relatos.sql
-- ======================================================================
-- Painel de métricas (movoapp.com.br/admin), aba "Relatos" (v201): relatos de problema
-- (user_feedback tipo 'problema', com contexto e revisão do agente; ver user_feedback_relatos.sql)
-- e os erros mais frequentes de client_errors. Desde v203 devolve também `prints` (relatos_prints.sql; rodar antes)
-- e todas as mensagens do "Fale com a gente" (problema, ideia, elogio, outro), com `tipo`. Só passa quem é admin (is_movo_admin).
-- Desde 19/10 (client_errors_revisao.sql; rodar antes) os erros trazem `novos` (não revisados), `revisao` e `revisado_em`.
-- Decisão do Andre (19/10): relatos ficam só no painel de métricas, não na aba Admin do app.
create or replace function public.admin_m_relatos(p_dias int default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'auth' as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'relatos', coalesce((
      select jsonb_agg(x order by x.lido, x.criado desc) from (
        select f.id, f.created_at as criado, f.tipo, u.email, nullif(trim(a.display_name), '') as nome,
               f.mensagem, f.contato, f.versao, f.origem, f.contexto, f.revisao, f.revisado_em, f.lido, f.prints
        from public.user_feedback f
        left join auth.users u on u.id = f.user_id
        left join public.app_data a on a.user_id = f.user_id
        where f.created_at >= now() - make_interval(days => greatest(p_dias, 1))
        order by f.created_at desc
        limit 200
      ) x), '[]'::jsonb),
    'erros', coalesce((
      select jsonb_agg(e order by e.novos desc, e.n desc) from (
        select ce.context as contexto, count(*) as n, count(distinct ce.user_id) as pessoas,
               max(ce.created_at) as ultimo, (array_agg(left(ce.message, 300) order by ce.created_at desc))[1] as exemplo,
               count(*) filter (where ce.revisado_em is null) as novos,
               count(distinct ce.user_id) filter (where ce.revisado_em is null) as novos_pessoas,
               max(ce.created_at) filter (where ce.revisado_em is null) as ultimo_novo,
               (array_agg(left(ce.message, 300) order by ce.created_at desc) filter (where ce.revisado_em is null))[1] as exemplo_novo,
               (array_agg(ce.revisao order by ce.revisado_em desc) filter (where ce.revisao is not null))[1] as revisao,
               max(ce.revisado_em) as revisado_em
        from public.client_errors ce
        where ce.created_at >= now() - make_interval(days => greatest(p_dias, 1))
        group by ce.context
        order by count(*) filter (where ce.revisado_em is null) desc, count(*) desc
        limit 50
      ) e), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_m_relatos(int) from public, anon;
grant execute on function public.admin_m_relatos(int) to authenticated;

create or replace function public.admin_m_relato_lido(p_id bigint, p_lido boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  update public.user_feedback set lido = p_lido where id = p_id;
end $$;
revoke all on function public.admin_m_relato_lido(bigint, boolean) from public, anon;
grant execute on function public.admin_m_relato_lido(bigint, boolean) to authenticated;

-- ======================================================================
-- painel_gestao.sql
-- ======================================================================
-- Painel de gestão (movoapp.com.br/admin, grupo "Operação"), decisão do Andre em 19/10/2026:
-- toda a gestão sai da aba Admin do app e vai para o painel. Aqui ficam só as peças NOVAS do banco:
--   1. checagem de admin por movo_admins (admin_identidade.sql) em todas as funções que tinham o e-mail escrito
--   2. registro de ações do admin (admin_log, só inserção) gravado por gatilho nas tabelas que o admin muda
--   3. contador de pendências, ficha de conta (+ exportar e apagar a pedido), desafios, integrações e recados
-- As funções admin_* antigas continuam as mesmas; o painel só passou a chamá-las.
-- Requer: admin_identidade.sql, admin_metricas.sql (_m_site), coach_*, billing_base.sql, challenge_acertos.sql.

-- ---------- 1. funções antigas: e-mail escrito -> is_movo_admin()/movo_admin_uid() ----------
-- Os arquivos do repositório já foram corrigidos; este bloco ajusta o que estiver no banco com o texto antigo.
do $$
declare f record; def text;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname not in ('is_movo_admin', 'movo_admin_uid')
      and p.prosrc ~ '\(select email from auth\.users where id = [a-z_.()]+\) (=|is distinct from) ''ardurso@gmail\.com'''
  loop
    def := pg_get_functiondef(f.oid);
    def := regexp_replace(def, '\(select email from auth\.users where id = auth\.uid\(\)\) is distinct from ''ardurso@gmail\.com''', 'not public.is_movo_admin()', 'g');
    def := regexp_replace(def, '\(select email from auth\.users where id = auth\.uid\(\)\) = ''ardurso@gmail\.com''', 'public.is_movo_admin()', 'g');
    def := regexp_replace(def, '\(select email from auth\.users where id = ([a-z_]+)\) is distinct from ''ardurso@gmail\.com''', 'not public.movo_admin_uid(\1)', 'g');
    def := regexp_replace(def, '\(select email from auth\.users where id = ([a-z_]+)\) = ''ardurso@gmail\.com''', 'public.movo_admin_uid(\1)', 'g');
    execute def;
  end loop;
end $$;

-- ---------- 2. registro de ações do admin ----------
create table if not exists public.admin_log (
  id bigserial primary key,
  criado_em timestamptz not null default now(),
  admin_id uuid,               -- sem FK: o registro sobrevive à conta
  acao text not null,          -- insert/update/delete (gatilho) ou nome da ação (exportar_conta, apagar_conta, recado...)
  tabela text,
  alvo_user uuid,              -- conta afetada, quando houver
  alvo text,                   -- chave legível (chave do app_config, nome da prova, exercício...)
  antes jsonb,
  depois jsonb);
create index if not exists admin_log_criado on public.admin_log(criado_em desc);
create index if not exists admin_log_alvo on public.admin_log(alvo_user, criado_em desc);
alter table public.admin_log enable row level security;
revoke all on public.admin_log from anon, authenticated;

create or replace function public._admin_log_imutavel() returns trigger language plpgsql as $$
begin raise exception 'admin_log_imutavel'; end $$;
create or replace trigger admin_log_imutavel before update or delete on public.admin_log
  for each row execute function public._admin_log_imutavel();

create or replace function public._admin_registrar(p_acao text, p_alvo_user uuid, p_alvo text, p_antes jsonb, p_depois jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.admin_log(admin_id, acao, tabela, alvo_user, alvo, antes, depois)
  values (auth.uid(), p_acao, null, p_alvo_user, p_alvo, p_antes, p_depois);
$$;
revoke all on function public._admin_registrar(text, uuid, text, jsonb, jsonb) from public, anon, authenticated;

-- Gatilho: só grava quando quem mudou é admin (o uso normal das pessoas não entra).
create or replace function public._admin_log_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; k jsonb; u text;
begin
  if not public.is_movo_admin() then return null; end if;
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and o = n then return null; end if;
  k := coalesce(n, o);
  u := coalesce(k->>'user_id', k->>'criada_por');
  insert into public.admin_log(admin_id, acao, tabela, alvo_user, alvo, antes, depois)
  values (auth.uid(), lower(tg_op), tg_table_name,
    case when u ~ '^[0-9a-f-]{36}$' then u::uuid end,
    coalesce(k->>'chave', k->>'nome', k->>'feature', k->>'exercicio_id', k->>'id'),
    o, n);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['coach_profiles','assinaturas','app_config','feature_access','shared_races',
                           'exercise_review','catalogo_exercicios','catalogo_aliases','catalogo_grupos'] loop
    if to_regclass('public.' || t) is not null then
      execute format('create or replace trigger admin_log_%s after insert or update or delete on public.%I for each row execute function public._admin_log_trg()', t, t);
    end if;
  end loop;
end $$;

create or replace function public.admin_m_registro(p_dias int default 30, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by x.criado_em desc) from (
    select l.id, l.criado_em, l.acao, l.tabela, l.alvo, l.alvo_user, l.antes, l.depois,
      (select email from auth.users where id = l.admin_id) as admin_email,
      (select email from auth.users where id = l.alvo_user) as alvo_email
    from public.admin_log l
    where l.criado_em >= now() - make_interval(days => greatest(1, least(p_dias, 365)))
      and (p_user is null or l.alvo_user = p_user)
    order by l.criado_em desc limit 300) x), '[]'::jsonb);
end $$;

-- ---------- 3a. pendências (contador do painel e do atalho no app) ----------
create or replace function public.admin_m_pendencias() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  r := jsonb_build_object(
    'treinadores', (select count(*) from coach_profiles where status = 'em_analise'),
    'catalogo', (select count(*) from exercise_review where status = 'pendente'),
    'relatos', (select count(*) from user_feedback where tipo = 'problema' and not coalesce(lido, false)),
    'feedback', (select count(*) from user_feedback where tipo <> 'problema' and not coalesce(lido, false)),
    'contestacoes', (select count(*) from challenge_acerto_status s
                      where s.contested_at is not null and s.received_at is null and s.forgiven_at is null));
  return r || jsonb_build_object('total', (select sum(v::int) from jsonb_each_text(r) x(k, v)));
end $$;

-- ---------- 3b. ficha de conta ----------
create or replace function public.admin_m_conta(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u record;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select id, email, created_at, last_sign_in_at into u from auth.users where id = p_user;
  if not found then return null; end if;
  -- Só contagens e vínculos: treinos, cargas e notas da pessoa não aparecem aqui.
  return jsonb_build_object(
    'id', u.id, 'email', u.email, 'cadastro', u.created_at, 'ultimo_login', u.last_sign_in_at,
    'admin', public.movo_admin_uid(p_user),
    'nome', (select nullif(trim(display_name), '') from app_data where user_id = p_user),
    'origem', (select to_jsonb(o) - 'user_id' from user_origem o where o.user_id = p_user),
    'uso', (select to_jsonb(s) - 'user_id' - 'email' from public.admin_usage_stats() s where s.user_id = p_user),
    'ultima_abertura', (select jsonb_build_object('em', opened_at, 'versao', versao, 'host', host, 'instalado', instalado, 'site', public._m_site(host, versao))
                        from app_opens where user_id = p_user order by opened_at desc limit 1),
    'planos', coalesce((select jsonb_agg(to_jsonb(a) - 'user_id' - 'gateway_ref') from assinaturas a where a.user_id = p_user), '[]'::jsonb),
    'treinadores', coalesce((select jsonb_agg(jsonb_build_object('nome', cp.nome_exibicao, 'status', l.status, 'desde', coalesce(l.accepted_at, l.created_at)))
                             from coach_links l left join coach_profiles cp on cp.user_id = l.coach_id
                             where l.student_id = p_user and l.status not in ('encerrado', 'recusado')), '[]'::jsonb),
    'como_treinador', (select jsonb_build_object('status', cp.status, 'nome', cp.nome_exibicao,
                         'alunos', (select count(*) from coach_links l where l.coach_id = p_user and l.status = 'ativo'))
                       from coach_profiles cp where cp.user_id = p_user),
    'strava', (select jsonb_build_object('ultima_sync', last_sync_at, 'atualizado', updated_at) from strava_connections where user_id = p_user),
    'desafios', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'inicio', c.start_date, 'semanas', c.weeks, 'dono', c.owner_id = p_user) order by c.start_date desc)
                          from challenges c join challenge_members m on m.challenge_id = c.id and m.user_id = p_user), '[]'::jsonb),
    'erros', coalesce((select jsonb_agg(x) from (select created_at, context, left(message, 300) as message from client_errors
                                                where user_id = p_user order by created_at desc limit 10) x), '[]'::jsonb),
    'mensagens', coalesce((select jsonb_agg(x) from (select id, created_at, tipo, left(mensagem, 500) as mensagem, lido from user_feedback
                                                    where user_id = p_user order by created_at desc limit 10) x), '[]'::jsonb),
    'registro', coalesce((select jsonb_agg(x) from (select criado_em, acao, tabela, alvo from admin_log
                                                   where alvo_user = p_user order by criado_em desc limit 20) x), '[]'::jsonb));
end $$;

-- Roda uma função "my_*" como se fosse a pessoa (pedido LGPD feito ao suporte). Volta à sessão do admin no fim.
create or replace function public._admin_como(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end $$;
revoke all on function public._admin_como(uuid) from public, anon, authenticated;

create or replace function public.admin_m_conta_exportar(p_user uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a_sub text := current_setting('request.jwt.claim.sub', true); a_cl text := current_setting('request.jwt.claims', true); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'conta_nao_encontrada'; end if;
  perform public._admin_registrar('exportar_conta', p_user, null, null, null);
  perform public._admin_como(p_user);
  r := public.export_my_data();
  perform set_config('request.jwt.claim.sub', coalesce(a_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(a_cl, ''), true);
  return r;
end $$;

-- Apagar a conta a pedido da pessoa. Exige o e-mail digitado igual ao da conta; nunca apaga um admin.
-- O registro guarda só o id (sem e-mail), para não manter dado pessoal depois da exclusão.
create or replace function public.admin_m_conta_apagar(p_user uuid, p_email text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a_sub text := current_setting('request.jwt.claim.sub', true); a_cl text := current_setting('request.jwt.claims', true); mail text;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if public.movo_admin_uid(p_user) then raise exception 'nao_pode_apagar_admin'; end if;
  select email into mail from auth.users where id = p_user;
  if mail is null then raise exception 'conta_nao_encontrada'; end if;
  if lower(trim(coalesce(p_email, ''))) <> lower(mail) then raise exception 'email_nao_confere'; end if;
  perform public._admin_registrar('apagar_conta', p_user, null, null, null);
  perform public._admin_como(p_user);
  perform public.delete_my_account();
  perform set_config('request.jwt.claim.sub', coalesce(a_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(a_cl, ''), true);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 3c. desafios e prêmios (só leitura: o livro-caixa é imutável e o Movo não toca no dinheiro) ----------
create or replace function public._num(p text) returns numeric language sql immutable as $$
  select case when p ~ '^\s*[0-9]+([.,][0-9]+)?\s*$' then replace(trim(p), ',', '.')::numeric else 0 end
$$;

create or replace function public.admin_m_desafios() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by x.inicio desc) from (
    select c.id, c.nome, c.start_date as inicio, c.weeks as semanas, c.start_date + c.weeks * 7 as fim,
      case when current_date < c.start_date then 'antes' when current_date < c.start_date + c.weeks * 7 then 'andamento' else 'encerrado' end as status,
      (select coalesce(nullif(trim(a.display_name), ''), u.email) from auth.users u left join app_data a on a.user_id = u.id where u.id = c.owner_id) as criador,
      (select count(*) from challenge_members m where m.challenge_id = c.id) as pessoas,
      public._num(c.stakes->>'semana_valor') as semana_valor, public._num(c.stakes->>'final_valor') as final_valor,
      (select count(*) from challenge_ledger l where l.challenge_id = c.id) as lancamentos,
      (select coalesce(sum(l.valor_cents), 0) from challenge_ledger l where l.challenge_id = c.id) as total_cents,
      (select count(*) from challenge_ledger l left join challenge_acerto_status s on s.ledger_id = l.id
        where l.challenge_id = c.id and s.received_at is null and s.forgiven_at is null) as abertos,
      (select count(*) from challenge_ledger l join challenge_acerto_status s on s.ledger_id = l.id
        where l.challenge_id = c.id and s.contested_at is not null and s.received_at is null and s.forgiven_at is null) as contestados,
      (select count(*) from challenge_ledger l left join challenge_acerto_status s on s.ledger_id = l.id
        where l.challenge_id = c.id and s.received_at is null and s.forgiven_at is null and l.created_at < now() - interval '14 days') as parados
    from challenges c) x), '[]'::jsonb);
end $$;

create or replace function public.admin_m_desafio(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return (select jsonb_build_object(
    'id', c.id, 'nome', c.nome, 'inicio', c.start_date, 'semanas', c.weeks, 'regras', c.rules, 'stakes', c.stakes,
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object('id', m.user_id, 'nome', coalesce(nullif(trim(a.display_name), ''), u.email), 'email', u.email, 'entrou', m.joined_at) order by m.joined_at)
                         from challenge_members m left join auth.users u on u.id = m.user_id left join app_data a on a.user_id = m.user_id
                         where m.challenge_id = c.id), '[]'::jsonb),
    'livro', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'tipo', l.kind, 'semana', l.week_idx, 'valor_cents', l.valor_cents, 'em', l.created_at,
                         'de', coalesce(nullif(trim(af.display_name), ''), uf.email), 'para', coalesce(nullif(trim(at.display_name), ''), ut.email),
                         'pago', s.paid_at, 'recebido', s.received_at, 'perdoado', s.forgiven_at, 'contestado', s.contested_at, 'nota', s.contest_note) order by l.created_at, l.week_idx)
                       from challenge_ledger l
                       left join challenge_acerto_status s on s.ledger_id = l.id
                       left join auth.users uf on uf.id = l.from_user left join app_data af on af.user_id = l.from_user
                       left join auth.users ut on ut.id = l.to_user left join app_data at on at.user_id = l.to_user
                       where l.challenge_id = c.id), '[]'::jsonb))
    from challenges c where c.id = p_id);
end $$;

-- ---------- 3d. integrações (Strava e e-mails) ----------
create or replace function public.admin_m_integracoes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'strava_limite', 10,
    'strava', coalesce((select jsonb_agg(jsonb_build_object('id', s.user_id, 'nome', coalesce(nullif(trim(a.display_name), ''), u.email), 'email', u.email,
                          'ultima_sync', s.last_sync_at, 'atualizado', s.updated_at) order by s.last_sync_at desc nulls last)
                        from strava_connections s left join auth.users u on u.id = s.user_id left join app_data a on a.user_id = s.user_id), '[]'::jsonb),
    'avisos_7d', coalesce((select jsonb_object_agg(tipo, n) from (select tipo, count(*) n from aviso_email_log where created_at >= now() - interval '7 days' group by tipo) x), '{}'::jsonb),
    'convites_7d', coalesce((select jsonb_object_agg(coalesce(kind, 'convite'), n) from (select kind, count(*) n from convite_email_log where created_at >= now() - interval '7 days' group by kind) x), '{}'::jsonb),
    'no_limite_dia', (select count(*) from (
        select from_user, created_at::date from convite_email_log where created_at >= now() - interval '7 days' group by 1, 2 having count(*) >= 15
        union all
        select from_user, created_at::date from aviso_email_log where created_at >= now() - interval '7 days' group by 1, 2 having count(*) >= 15) z));
end $$;

-- ---------- 3e. recados para grupos de usuários (só dentro do app; e-mail em massa fica para depois, com custo aprovado) ----------
create table if not exists public.admin_recados (
  id bigserial primary key,
  titulo text not null check (length(titulo) between 1 and 80),
  texto text not null check (length(texto) between 1 and 400),
  botao_txt text check (botao_txt is null or length(botao_txt) <= 30),
  botao_url text check (botao_url is null or botao_url ~ '^https://'),
  publico text not null check (publico in ('todos', 'inativos', 'treinadores', 'desafio_premio', 'lista')),
  dias_inativo int,
  lista uuid[],
  ativo boolean not null default true,
  valido_ate timestamptz not null,
  criado_em timestamptz not null default now(),
  criado_por uuid);
alter table public.admin_recados enable row level security;
revoke all on public.admin_recados from anon, authenticated;

create table if not exists public.recado_vistos (
  recado_id bigint not null references public.admin_recados(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  visto_em timestamptz not null default now(),
  clicou_em timestamptz,
  dispensado_em timestamptz,
  primary key (recado_id, user_id));
alter table public.recado_vistos enable row level security;
revoke all on public.recado_vistos from anon, authenticated;

create or replace function public._recado_para(r public.admin_recados, p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case r.publico
    when 'todos' then true
    when 'lista' then p_uid = any (coalesce(r.lista, '{}'))
    when 'treinadores' then exists (select 1 from coach_profiles c where c.user_id = p_uid and c.status = 'ativo')
    when 'desafio_premio' then exists (select 1 from challenge_members m join challenges c on c.id = m.challenge_id
                                        where m.user_id = p_uid and current_date < c.start_date + c.weeks * 7
                                          and public._num(c.stakes->>'semana_valor') + public._num(c.stakes->>'final_valor') > 0)
    -- "inativos": ficou N dias sem abrir antes do recado ser criado (quem voltar a abrir vê)
    when 'inativos' then coalesce((select max(o.opened_at) from app_opens o where o.user_id = p_uid and o.opened_at < r.criado_em), '-infinity')
                          < r.criado_em - make_interval(days => greatest(1, coalesce(r.dias_inativo, 14)))
    else false end
$$;

-- App: recados ativos para mim, ainda não dispensados.
create or replace function public.meus_recados() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); r jsonb;
begin
  if uid is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'titulo', a.titulo, 'texto', a.texto, 'botao_txt', a.botao_txt, 'botao_url', a.botao_url) order by a.criado_em desc), '[]'::jsonb)
    into r
  from admin_recados a
  where a.ativo and a.valido_ate > now() and public._recado_para(a, uid)
    and not exists (select 1 from recado_vistos v where v.recado_id = a.id and v.user_id = uid and v.dispensado_em is not null);
  insert into recado_vistos(recado_id, user_id)
    select (x->>'id')::bigint, uid from jsonb_array_elements(r) x on conflict do nothing;
  return r;
end $$;

create or replace function public.recado_marcar(p_id bigint, p_acao text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or p_acao not in ('clicou', 'dispensou') then return; end if;
  insert into recado_vistos(recado_id, user_id) values (p_id, uid) on conflict do nothing;
  update recado_vistos set clicou_em = case when p_acao = 'clicou' then coalesce(clicou_em, now()) else clicou_em end,
                           dispensado_em = case when p_acao = 'dispensou' then coalesce(dispensado_em, now()) else dispensado_em end
   where recado_id = p_id and user_id = uid;
end $$;

-- Painel: quantas pessoas receberiam (prévia antes de publicar).
create or replace function public.admin_m_recado_previa(p_publico text, p_dias int default null, p_lista uuid[] default null) returns int
language plpgsql stable security definer set search_path = public as $$
declare r public.admin_recados;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  r.publico := p_publico; r.dias_inativo := p_dias; r.lista := p_lista; r.criado_em := now();
  return (select count(*) from auth.users u where public._recado_para(r, u.id));
end $$;

create or replace function public.admin_m_recados() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by x.criado_em desc) from (
    select a.*, (select count(*) from recado_vistos v where v.recado_id = a.id) as viram,
      (select count(*) from recado_vistos v where v.recado_id = a.id and v.clicou_em is not null) as clicaram,
      (select count(*) from recado_vistos v where v.recado_id = a.id and v.dispensado_em is not null) as dispensaram
    from admin_recados a order by a.criado_em desc limit 50) x), '[]'::jsonb);
end $$;

create or replace function public.admin_m_recado_salvar(p jsonb) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare novo public.admin_recados;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  insert into admin_recados(titulo, texto, botao_txt, botao_url, publico, dias_inativo, lista, valido_ate, criado_por)
  values (trim(p->>'titulo'), trim(p->>'texto'), nullif(trim(p->>'botao_txt'), ''), nullif(trim(p->>'botao_url'), ''),
          p->>'publico', nullif(p->>'dias_inativo', '')::int,
          case when jsonb_typeof(p->'lista') = 'array' then (select array_agg(x::uuid) from jsonb_array_elements_text(p->'lista') x) end,
          now() + make_interval(days => greatest(1, least(coalesce(nullif(p->>'dias', '')::int, 7), 60))), auth.uid())
  returning * into novo;
  perform public._admin_registrar('recado_publicado', null, novo.titulo, null, to_jsonb(novo));
  return novo.id;
end $$;

create or replace function public.admin_m_recado_encerrar(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  update admin_recados set ativo = false where id = p_id;
  perform public._admin_registrar('recado_encerrado', null, p_id::text, null, null);
end $$;

-- ---------- permissões: tudo admin_m_* só para quem está logado (a função confere se é admin) ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname in ('admin_m_registro','admin_m_pendencias','admin_m_conta','admin_m_conta_exportar','admin_m_conta_apagar',
                                                         'admin_m_desafios','admin_m_desafio','admin_m_integracoes','admin_m_recado_previa','admin_m_recados',
                                                         'admin_m_recado_salvar','admin_m_recado_encerrar','meus_recados','recado_marcar'))
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- ======================================================================
-- recado_email.sql
-- ======================================================================
-- Recados por e-mail (aprovado pelo Andre em 20/10/2026, "dentro do limite do Resend") e impacto de apagar uma conta.
-- Rodar depois de painel_gestao.sql. Quem envia é a edge function recado-email (Resend); aqui ficam fila, limites e saída da lista.
-- Limites: o plano grátis do Resend dá 100 e-mails/dia e 3.000/mês para a conta toda (inclui login e avisos),
-- então os recados usam no máximo 80/dia e 2.000/mês. O resto fica na fila e sai ao tocar "Enviar o restante" no dia seguinte.

create table if not exists public.email_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),  -- vai no link "sair da lista" (movoapp.com.br/sair/?t=...)
  sem_recados_em timestamptz);                           -- preenchido = não recebe recados por e-mail
alter table public.email_prefs enable row level security;
revoke all on public.email_prefs from anon, authenticated;

create table if not exists public.recado_emails (
  recado_id bigint not null references public.admin_recados(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  enviado_em timestamptz not null default now(),
  primary key (recado_id, user_id));
alter table public.recado_emails enable row level security;
revoke all on public.recado_emails from anon, authenticated;

create or replace function public._recado_email_cota() returns jsonb
language sql stable security definer set search_path = public as $$
  with b as (select (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') dia,
                    (date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') mes)
  select jsonb_build_object(
    'dia_max', 80, 'mes_max', 2000,
    'hoje', (select count(*) from recado_emails e, b where e.enviado_em >= b.dia),
    'mes', (select count(*) from recado_emails e, b where e.enviado_em >= b.mes))
$$;

-- Quem ainda deve receber este recado por e-mail (público do recado, e-mail confirmado, não saiu da lista, ainda não recebeu).
create or replace function public._recado_email_pendentes(r public.admin_recados)
returns table (user_id uuid, email text, nome text)
language sql stable security definer set search_path = public as $$
  select u.id, u.email::text, nullif(trim(a.display_name), '')
  from auth.users u
  left join app_data a on a.user_id = u.id
  left join email_prefs p on p.user_id = u.id
  where u.email is not null and u.email_confirmed_at is not null
    and p.sem_recados_em is null
    and public._recado_para(r, u.id)
    and not exists (select 1 from recado_emails e where e.recado_id = r.id and e.user_id = u.id)
$$;

-- Edge function: lote a enviar agora (respeita a cota) + texto do recado.
create or replace function public.admin_m_recado_email_fila(p_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r public.admin_recados; c jsonb; cota int; lote jsonb; pend int;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select * into r from admin_recados where id = p_id;
  if not found then raise exception 'recado_nao_encontrado'; end if;
  if not r.ativo or r.valido_ate <= now() then raise exception 'recado_encerrado'; end if;
  c := public._recado_email_cota();
  cota := greatest(0, least((c->>'dia_max')::int - (c->>'hoje')::int, (c->>'mes_max')::int - (c->>'mes')::int));
  insert into email_prefs(user_id) select q.user_id from public._recado_email_pendentes(r) q on conflict do nothing;
  select count(*) into pend from public._recado_email_pendentes(r);
  select coalesce(jsonb_agg(jsonb_build_object('id', q.user_id, 'email', q.email, 'nome', q.nome, 'token', p.token)), '[]'::jsonb) into lote
  from (select * from public._recado_email_pendentes(r) limit cota) q join email_prefs p on p.user_id = q.user_id;
  return jsonb_build_object('recado', jsonb_build_object('titulo', r.titulo, 'texto', r.texto, 'botao_txt', r.botao_txt, 'botao_url', r.botao_url),
                            'pendentes', pend, 'cota', cota, 'lote', lote);
end $$;

-- Edge function: marca quem recebeu (só depois do Resend aceitar).
create or replace function public.admin_m_recado_email_ok(p_id bigint, p_users uuid[]) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  insert into recado_emails(recado_id, user_id) select p_id, x from unnest(p_users) x on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then perform public._admin_registrar('recado_email', null, p_id::text, null, jsonb_build_object('enviados', n)); end if;
  return n;
end $$;

-- Página pública movoapp.com.br/sair/: sai da lista de recados por e-mail (só com o token do link).
create or replace function public.email_sair(p_token uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  update email_prefs set sem_recados_em = coalesce(sem_recados_em, now()) where token = p_token;
  return found;
end $$;

-- Painel: lista de recados com os números de e-mail.
create or replace function public.admin_m_recados() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  c := public._recado_email_cota();
  return jsonb_build_object('cota', c, 'sairam', (select count(*) from email_prefs where sem_recados_em is not null),
    'recados', coalesce((select jsonb_agg(x order by x.criado_em desc) from (
      select a.*, (select count(*) from recado_vistos v where v.recado_id = a.id) as viram,
        (select count(*) from recado_vistos v where v.recado_id = a.id and v.clicou_em is not null) as clicaram,
        (select count(*) from recado_vistos v where v.recado_id = a.id and v.dispensado_em is not null) as dispensaram,
        (select count(*) from recado_emails e where e.recado_id = a.id) as emails,
        case when a.ativo and a.valido_ate > now() then (select count(*) from public._recado_email_pendentes(a)) else 0 end as emails_pendentes
      from admin_recados a order by a.criado_em desc limit 50) x), '[]'::jsonb));
end $$;

-- Painel: o que some junto ao apagar uma conta (mostrado antes de confirmar).
create or replace function public.admin_m_conta_impacto(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'acertos_abertos', (select count(*) from challenge_ledger l left join challenge_acerto_status s on s.ledger_id = l.id
                         where (l.from_user = p_user or l.to_user = p_user) and s.received_at is null and s.forgiven_at is null),
    'desafios_dono', (select count(*) from challenges where owner_id = p_user),
    'alunos', (select count(*) from coach_links where coach_id = p_user and status in ('ativo', 'congelado')),
    'strava', exists (select 1 from strava_connections where user_id = p_user));
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('admin_m_recado_email_fila', 'admin_m_recado_email_ok', 'admin_m_recados', 'admin_m_conta_impacto',
                                                         '_recado_email_cota', '_recado_email_pendentes', 'email_sair')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.proname = 'email_sair' then execute format('grant execute on function %s to anon, authenticated', f.sig);
    elsif f.proname like 'admin_m_%' then execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;

-- ======================================================================
-- coach_plano.sql
-- ======================================================================
-- Fase 2 (v207): o treinador envia um plano de várias semanas, e o aluno pode ligar o aceite automático.
-- Plano = envio com tipo 'plano' e payload {semana:{dias,fichas}, semanas, inicio, nome, progressao}.
-- Aceite automático: opção do aluno no vínculo (desligada por padrão, revogável; decisão do Andre em 20/10).
-- Idempotente. Rodar depois de coach_setup_v2.sql.

alter table public.coach_assignments drop constraint if exists coach_assignments_tipo_check;
alter table public.coach_assignments add constraint coach_assignments_tipo_check
  check (tipo in ('semana', 'ficha', 'corrida', 'plano'));

alter table public.coach_links add column if not exists aceite_auto boolean not null default false;

-- Aluno liga ou desliga o aceite automático do próprio vínculo.
create or replace function public.coach_set_aceite_auto(p_link uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_links set aceite_auto = coalesce(p_on, false)
   where id = p_link and student_id = auth.uid() and status in ('ativo', 'pausado', 'congelado');
  if not found then raise exception 'vínculo não encontrado'; end if;
  insert into public.coach_audit (link_id, ator, acao, meta)
  values (p_link, auth.uid(), 'aceite_auto', jsonb_build_object('ligado', coalesce(p_on, false)));
end;
$$;
revoke execute on function public.coach_set_aceite_auto(uuid, boolean) from public, anon;
grant execute on function public.coach_set_aceite_auto(uuid, boolean) to authenticated;

-- coach_my_coach passa a devolver aceite_auto.
create or replace function public.coach_my_coach()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'link_id', l.id, 'status', l.status, 'permissions', l.permissions,
      'coach_nome', coalesce(p.nome_exibicao, 'Treinador'), 'coach_uid', l.coach_id,
      'coach_bio', p.bio, 'coach_cref', p.cref, 'coach_status', coalesce(p.status, 'suspenso'),
      'accepted_at', l.accepted_at, 'aceite_auto', l.aceite_auto
    ) order by l.accepted_at desc)
    from public.coach_links l
    left join public.coach_profiles p on p.user_id = l.coach_id
    where l.student_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado')
  ), '[]'::jsonb);
end;
$$;

-- Treinador consulta se o aluno aplica automaticamente (aviso no envio).
create or replace function public.coach_link_aceite_auto(p_link uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select l.aceite_auto from public.coach_links l
    where l.id = p_link and l.coach_id = auth.uid() and l.status = 'ativo'), false);
end;
$$;
revoke execute on function public.coach_link_aceite_auto(uuid) from public, anon;
grant execute on function public.coach_link_aceite_auto(uuid) to authenticated;

-- Permissão nova: o treinador ajusta a semana inteira (tira fichas e atividades do aluno no envio).
-- Ausente = desligada. Mesmas chaves de coach_contato.sql + ajustar_semana.
create or replace function public.coach_clean_perms(p jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ver_treinos', coalesce((p->>'ver_treinos')::boolean, true),
    'ver_cargas', coalesce((p->>'ver_cargas')::boolean, true),
    'ver_esforco_dor', coalesce((p->>'ver_esforco_dor')::boolean, false),
    'ver_corrida', coalesce((p->>'ver_corrida')::boolean, true),
    'ver_contato', coalesce((p->>'ver_contato')::boolean, false),
    'ajustar_semana', coalesce((p->>'ajustar_semana')::boolean, false)
  );
$$;
revoke execute on function public.coach_clean_perms(jsonb) from public, anon;
grant execute on function public.coach_clean_perms(jsonb) to authenticated;

-- ======================================================================
-- push_setup.sql
-- ======================================================================
-- Notificações push (Web Push, v214). O app inscreve o aparelho (push_salvar) e a edge function `enviar-push`
-- manda: (a) "treino novo do treinador", chamado pelo app do treinador depois de enviar; (b) teste para o próprio
-- aparelho; (c) resultado semanal dos desafios, pela função agendada no fim deste arquivo (segunda 9h de Brasília,
-- aprovada pelo Andre em 21/10). Sem lembrete diário nem cobrança de treino (decisão do Andre, 21/10).
-- Segredos da edge function: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:).
create table if not exists public.push_inscricoes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  ua text,
  tipos jsonb not null default '{"treinador": true, "desafios": true}'::jsonb,
  criado_em timestamptz not null default now(),
  ultimo_ok timestamptz,
  falhas int not null default 0
);
create index if not exists push_inscricoes_user_idx on public.push_inscricoes (user_id);
alter table public.push_inscricoes enable row level security;
revoke all on public.push_inscricoes from public, anon, authenticated;

-- O que foi enviado (para limitar a frequência e medir).
create table if not exists public.push_envios (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null,
  ref text not null default '',
  aparelhos int not null default 0,
  criado_em timestamptz not null default now()
);
create index if not exists push_envios_user_idx on public.push_envios (user_id, tipo, criado_em desc);
alter table public.push_envios enable row level security;
revoke all on public.push_envios from public, anon, authenticated;

-- Inscreve (ou atualiza) este aparelho para a pessoa logada. Um aparelho só tem um dono: trocar de conta move a inscrição.
create or replace function public.push_salvar(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null, p_tipos jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not authenticated'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'inscrição inválida'; end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'inscrição inválida'; end if;
  insert into public.push_inscricoes (user_id, endpoint, p256dh, auth, ua, tipos)
  values (me, p_endpoint, p_p256dh, p_auth, left(p_ua, 200), coalesce(p_tipos, '{"treinador": true, "desafios": true}'::jsonb))
  on conflict (endpoint) do update set user_id = me, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua,
    tipos = coalesce(p_tipos, public.push_inscricoes.tipos), falhas = 0;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.push_remover(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.push_inscricoes where endpoint = p_endpoint and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- Escolha do que receber (vale para todos os aparelhos da pessoa).
create or replace function public.push_tipos(p_tipos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.push_inscricoes set tipos = jsonb_build_object(
      'treinador', coalesce((p_tipos->>'treinador')::boolean, true),
      'desafios', coalesce((p_tipos->>'desafios')::boolean, true))
   where user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- Resultado semanal dos desafios: segunda às 9h de Brasília (12h UTC). O segredo da chamada fica no Vault e a
-- edge function confere com push_segredo_ok (mesmo esquema do alerta-saude).
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'push_cron_secret') then
    perform vault.create_secret(encode(gen_random_bytes(24), 'hex'), 'push_cron_secret');
  end if;
end $$;

create or replace function public.push_segredo_ok(p text)
returns boolean language sql security definer set search_path = public, vault as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'push_cron_secret' and decrypted_secret = p);
$$;
revoke all on function public.push_segredo_ok(text) from public, anon, authenticated;
grant execute on function public.push_segredo_ok(text) to service_role;

select cron.unschedule('push-desafios-semanal') where exists (select 1 from cron.job where jobname = 'push-desafios-semanal');
select cron.schedule('push-desafios-semanal', '0 12 * * 1', $job$
  select net.http_post(
    url := 'https://wgdhjkebfvcmgokxscvb.supabase.co/functions/v1/enviar-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
    body := '{"tipo":"desafios"}'::jsonb
  );
$job$);

-- A edge function usa o service_role, que neste projeto só tem o que é liberado tabela a tabela.
-- Sem isto o envio sai vazio (corrigido em 21/10, depois da v214).
grant select, insert, update, delete on public.push_inscricoes to service_role;
grant select, insert on public.push_envios to service_role;
grant select (id, nome, start_date, weeks, rules, stakes) on public.challenges to service_role;
grant select (challenge_id, user_id) on public.challenge_members to service_role;
grant select (challenge_id, user_id, date, tipo) on public.challenge_checkins to service_role;
grant select (challenge_id, date, from_user, to_user, status) on public.challenge_together to service_role;
grant select (user_id, display_name) on public.app_data to service_role;
grant select (id, coach_id, student_id, status) on public.coach_links to service_role;
grant select (user_id, nome_exibicao) on public.coach_profiles to service_role;

-- ======================================================================
-- fase4_medidas.sql
-- ======================================================================
-- Fase 4 (v219): Minhas medidas e fotos (aluno), avaliação e anamnese (treinador).
-- Seguro rodar de novo. Sem "drop" (o conector do Supabase cancela comandos destrutivos).
--
-- Dados de saúde (LGPD, dado sensível): medidas e fotos são do aluno, só ele grava. O treinador
-- só vê com a permissão "ver_medidas" (desligada por padrão) e vínculo ativo. A anamnese é pedida
-- pelo treinador, respondida pelo aluno e só aquele treinador vê; o aluno pode apagar as respostas.

-- 1. Minhas medidas -------------------------------------------------------------------------------
create table if not exists public.user_medidas (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  data date not null,
  peso numeric(5,1) check (peso is null or peso between 20 and 400),
  gordura numeric(4,1) check (gordura is null or gordura between 2 and 70),
  medidas jsonb not null default '{}'::jsonb,           -- cm: cintura, quadril, peito, braco, coxa, panturrilha, abdomen
  nota text check (nota is null or char_length(nota) <= 300),
  fotos text[] not null default '{}' check (cardinality(fotos) <= 3), -- caminhos no bucket "medidas"
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists user_medidas_user_data on public.user_medidas (user_id, data desc);
alter table public.user_medidas enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'user_medidas' and policyname = 'user_medidas_dono') then
    create policy user_medidas_dono on public.user_medidas for all to authenticated
      using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
end $$;
grant select, insert, update, delete on public.user_medidas to authenticated;

-- 2. Permissão nova no vínculo: ver_medidas (ausente = desligada). Mesmas chaves de coach_plano.sql.
create or replace function public.coach_clean_perms(p jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ver_treinos', coalesce((p->>'ver_treinos')::boolean, true),
    'ver_cargas', coalesce((p->>'ver_cargas')::boolean, true),
    'ver_esforco_dor', coalesce((p->>'ver_esforco_dor')::boolean, false),
    'ver_corrida', coalesce((p->>'ver_corrida')::boolean, true),
    'ver_contato', coalesce((p->>'ver_contato')::boolean, false),
    'ajustar_semana', coalesce((p->>'ajustar_semana')::boolean, false),
    'ver_medidas', coalesce((p->>'ver_medidas')::boolean, false)
  );
$$;
revoke execute on function public.coach_clean_perms(jsonb) from public, anon;
grant execute on function public.coach_clean_perms(jsonb) to authenticated;

-- O treinador (vínculo ativo + ver_medidas) pode ver as medidas e as fotos daquele aluno.
create or replace function public.medidas_coach_pode(p_aluno text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coach_links l
    where l.coach_id = auth.uid() and l.student_id::text = p_aluno and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_medidas')::boolean, false));
$$;
revoke execute on function public.medidas_coach_pode(text) from public, anon;
grant execute on function public.medidas_coach_pode(text) to authenticated;

create or replace function public.coach_aluno_medidas(p_link uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_aluno uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select l.student_id into v_aluno from public.coach_links l
    where l.id = p_link and l.coach_id = auth.uid() and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_medidas')::boolean, false);
  if v_aluno is null then return null; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'data', m.data, 'peso', m.peso, 'gordura', m.gordura,
      'medidas', m.medidas, 'nota', m.nota, 'fotos', m.fotos) order by m.data desc)
    from (select * from public.user_medidas where user_id = v_aluno order by data desc limit 60) m), '[]'::jsonb);
end;
$$;
revoke execute on function public.coach_aluno_medidas(uuid) from public, anon;
grant execute on function public.coach_aluno_medidas(uuid) to authenticated;

-- 3. Fotos: bucket PRIVADO "medidas", pasta = user_id, JPEG reduzido no aparelho (lado maior 1280px).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('medidas', 'medidas', false, 716800, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 716800, allowed_mime_types = array['image/jpeg'];
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_insert_own') then
    create policy medidas_insert_own on storage.objects for insert to authenticated
      with check (bucket_id = 'medidas' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_select_own_ou_treinador') then
    create policy medidas_select_own_ou_treinador on storage.objects for select to authenticated
      using (bucket_id = 'medidas' and ((storage.foldername(name))[1] = auth.uid()::text
        or public.medidas_coach_pode((storage.foldername(name))[1])));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_delete_own') then
    create policy medidas_delete_own on storage.objects for delete to authenticated
      using (bucket_id = 'medidas' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

-- 4. Avaliação física feita pelo treinador ------------------------------------------------------
-- O treinador grava (por RPC); o aluno vê as dele em "Minhas medidas", mesmo depois do vínculo acabar.
create table if not exists public.coach_avaliacoes (
  id uuid primary key default gen_random_uuid(),
  link_id uuid not null references public.coach_links(id) on delete cascade,
  coach_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references auth.users(id) on delete cascade,
  data date not null,
  peso numeric(5,1) check (peso is null or peso between 20 and 400),
  gordura numeric(4,1) check (gordura is null or gordura between 2 and 70),
  medidas jsonb not null default '{}'::jsonb,
  testes text check (testes is null or char_length(testes) <= 1000),
  nota text check (nota is null or char_length(nota) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists coach_avaliacoes_link on public.coach_avaliacoes (link_id, data desc);
create index if not exists coach_avaliacoes_aluno on public.coach_avaliacoes (student_id, data desc);
alter table public.coach_avaliacoes enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'coach_avaliacoes' and policyname = 'coach_avaliacoes_ler') then
    create policy coach_avaliacoes_ler on public.coach_avaliacoes for select to authenticated
      using (student_id = auth.uid() or exists (select 1 from public.coach_links l
        where l.id = link_id and l.coach_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado')));
  end if;
end $$;
grant select on public.coach_avaliacoes to authenticated;

-- Medidas aceitas (cm): só números entre 10 e 300 nas chaves conhecidas.
create or replace function public.medidas_limpar(p jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, round(v::numeric, 1)), '{}'::jsonb)
  from jsonb_each_text(coalesce(p, '{}'::jsonb)) as e(k, v)
  where k in ('cintura', 'quadril', 'peito', 'braco', 'coxa', 'panturrilha', 'abdomen')
    and v ~ '^[0-9]+(\.[0-9]+)?$' and v::numeric between 10 and 300;
$$;

create or replace function public.coach_avaliacao_salvar(p_link uuid, p_id uuid, p_data date, p_peso numeric,
  p_gordura numeric, p_medidas jsonb, p_testes text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; v public.coach_avaliacoes;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null then raise exception 'vinculo invalido'; end if;
  if p_data is null or p_data > current_date + 1 then raise exception 'data invalida'; end if;
  if p_id is null then
    insert into public.coach_avaliacoes (link_id, coach_id, student_id, data, peso, gordura, medidas, testes, nota)
    values (l.id, l.coach_id, l.student_id, p_data, p_peso, p_gordura, public.medidas_limpar(p_medidas),
      nullif(left(trim(coalesce(p_testes, '')), 1000), ''), nullif(left(trim(coalesce(p_nota, '')), 1000), ''))
    returning * into v;
  else
    update public.coach_avaliacoes set data = p_data, peso = p_peso, gordura = p_gordura, medidas = public.medidas_limpar(p_medidas),
      testes = nullif(left(trim(coalesce(p_testes, '')), 1000), ''), nota = nullif(left(trim(coalesce(p_nota, '')), 1000), ''), updated_at = now()
    where id = p_id and link_id = l.id returning * into v;
    if v.id is null then raise exception 'avaliacao nao encontrada'; end if;
  end if;
  return to_jsonb(v);
end;
$$;
revoke execute on function public.coach_avaliacao_salvar(uuid, uuid, date, numeric, numeric, jsonb, text, text) from public, anon;
grant execute on function public.coach_avaliacao_salvar(uuid, uuid, date, numeric, numeric, jsonb, text, text) to authenticated;

create or replace function public.coach_avaliacao_apagar(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.coach_avaliacoes a using public.coach_links l
    where a.id = p_id and l.id = a.link_id and l.coach_id = auth.uid() and l.status = 'ativo';
  return found;
end;
$$;
revoke execute on function public.coach_avaliacao_apagar(uuid) from public, anon;
grant execute on function public.coach_avaliacao_apagar(uuid) to authenticated;

-- O aluno vê as avaliações que recebeu, com o nome do treinador.
create or replace function public.minhas_avaliacoes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'data', a.data, 'peso', a.peso, 'gordura', a.gordura,
      'medidas', a.medidas, 'testes', a.testes, 'nota', a.nota, 'coach_nome', coalesce(p.nome_exibicao, 'Treinador')) order by a.data desc)
    from public.coach_avaliacoes a left join public.coach_profiles p on p.user_id = a.coach_id
    where a.student_id = auth.uid()), '[]'::jsonb);
end;
$$;
revoke execute on function public.minhas_avaliacoes() from public, anon;
grant execute on function public.minhas_avaliacoes() to authenticated;

-- 5. Anamnese: o treinador pede, o aluno responde, só aquele treinador vê -------------------------
create table if not exists public.coach_anamneses (
  link_id uuid primary key references public.coach_links(id) on delete cascade,
  coach_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references auth.users(id) on delete cascade,
  pedida_em timestamptz not null default now(),
  respostas jsonb check (respostas is null or pg_column_size(respostas) < 20000),
  respondida_em timestamptz
);
alter table public.coach_anamneses enable row level security; -- sem policies: só pelas RPCs abaixo

create or replace function public.coach_anamnese_pedir(p_link uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null then raise exception 'vinculo invalido'; end if;
  insert into public.coach_anamneses (link_id, coach_id, student_id) values (l.id, l.coach_id, l.student_id)
  on conflict (link_id) do update set pedida_em = now();
  return (select to_jsonb(a) from public.coach_anamneses a where a.link_id = l.id);
end;
$$;
revoke execute on function public.coach_anamnese_pedir(uuid) from public, anon;
grant execute on function public.coach_anamnese_pedir(uuid) to authenticated;

create or replace function public.coach_anamnese(p_link uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return (select jsonb_build_object('pedida_em', a.pedida_em, 'respondida_em', a.respondida_em, 'respostas', a.respostas)
    from public.coach_anamneses a join public.coach_links l on l.id = a.link_id
    where a.link_id = p_link and l.coach_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado'));
end;
$$;
revoke execute on function public.coach_anamnese(uuid) from public, anon;
grant execute on function public.coach_anamnese(uuid) to authenticated;

-- Aluno: pedidos e respostas dele (de vínculos ativos), com o nome do treinador.
create or replace function public.minhas_anamneses()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('link_id', a.link_id, 'pedida_em', a.pedida_em, 'respondida_em', a.respondida_em,
      'respostas', a.respostas, 'coach_nome', coalesce(p.nome_exibicao, 'Treinador')) order by a.pedida_em desc)
    from public.coach_anamneses a join public.coach_links l on l.id = a.link_id
    left join public.coach_profiles p on p.user_id = a.coach_id
    where a.student_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado')), '[]'::jsonb);
end;
$$;
revoke execute on function public.minhas_anamneses() from public, anon;
grant execute on function public.minhas_anamneses() to authenticated;

-- Responder (p_respostas) ou apagar as respostas (p_respostas null).
create or replace function public.anamnese_responder(p_link uuid, p_respostas jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_respostas is not null and (jsonb_typeof(p_respostas) <> 'object' or pg_column_size(p_respostas) >= 20000) then
    raise exception 'respostas invalidas';
  end if;
  update public.coach_anamneses set respostas = p_respostas, respondida_em = case when p_respostas is null then null else now() end
    where link_id = p_link and student_id = auth.uid();
  return found;
end;
$$;
revoke execute on function public.anamnese_responder(uuid, jsonb) from public, anon;
grant execute on function public.anamnese_responder(uuid, jsonb) to authenticated;

-- ======================================================================
-- fase4_videos.sql
-- ======================================================================
-- Fase 4 (v219): vídeos. Seguro rodar de novo. Sem "drop" (o conector do Supabase cancela comandos destrutivos).
--
-- Bucket PRIVADO "videos", compactado no aparelho antes de subir:
--   <aluno>/sessao/...     vídeo da execução no comentário da sessão (até 30 s). O treinador vê só com
--                          vínculo ativo, "ver_treinos" e "ver_cargas" ligados e por 90 dias. O app do aluno
--                          apaga os arquivos com mais de 90 dias e os de quando não há mais treinador.
--   <treinador>/biblioteca/...  vídeo próprio do treinador (até 60 s), sem expirar, até 20 por treinador.
--                          Os alunos com vínculo ativo veem. A lista fica em coach_videos.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', false, 12582912, array['video/mp4', 'video/webm', 'video/quicktime'])
on conflict (id) do update set public = false, file_size_limit = 12582912, allowed_mime_types = array['video/mp4', 'video/webm', 'video/quicktime'];

create table if not exists public.coach_videos (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exercicio text not null check (char_length(exercicio) between 1 and 80),
  path text not null check (char_length(path) <= 200),
  dur int check (dur is null or dur between 1 and 61),
  created_at timestamptz not null default now()
);
create index if not exists coach_videos_coach on public.coach_videos (coach_id, created_at desc);
alter table public.coach_videos enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'coach_videos' and policyname = 'coach_videos_dono') then
    create policy coach_videos_dono on public.coach_videos for all to authenticated
      using (coach_id = auth.uid()) with check (coach_id = auth.uid() and split_part(path, '/', 1) = auth.uid()::text);
  end if;
end $$;
grant select, insert, update, delete on public.coach_videos to authenticated;

-- Cota: 20 vídeos por treinador na biblioteca (conta os arquivos, não as linhas).
create or replace function public.videos_biblioteca_cabe()
returns boolean language sql stable security definer set search_path = public, storage as $$
  select (select count(*) from storage.objects o where o.bucket_id = 'videos' and o.name like auth.uid()::text || '/biblioteca/%') < 20;
$$;
revoke execute on function public.videos_biblioteca_cabe() from public, anon;
grant execute on function public.videos_biblioteca_cabe() to authenticated;

-- Treinador vê o vídeo de sessão do aluno: vínculo ativo, treinos e cargas compartilhados, até 90 dias.
create or replace function public.videos_coach_ve_sessao(p_aluno text, p_criado timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select p_criado > now() - interval '90 days' and exists (select 1 from public.coach_links l
    where l.coach_id = auth.uid() and l.student_id::text = p_aluno and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_treinos')::boolean, true) and coalesce((l.permissions->>'ver_cargas')::boolean, true));
$$;
revoke execute on function public.videos_coach_ve_sessao(text, timestamptz) from public, anon;
grant execute on function public.videos_coach_ve_sessao(text, timestamptz) to authenticated;

-- Aluno vê o vídeo da biblioteca do treinador com quem tem vínculo ativo.
create or replace function public.videos_aluno_ve_biblioteca(p_coach text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coach_links l
    where l.student_id = auth.uid() and l.coach_id::text = p_coach and l.status = 'ativo');
$$;
revoke execute on function public.videos_aluno_ve_biblioteca(text) from public, anon;
grant execute on function public.videos_aluno_ve_biblioteca(text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'videos_insert_own') then
    create policy videos_insert_own on storage.objects for insert to authenticated
      with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text
        and ((storage.foldername(name))[2] = 'sessao'
          or ((storage.foldername(name))[2] = 'biblioteca' and public.videos_biblioteca_cabe())));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'videos_select') then
    create policy videos_select on storage.objects for select to authenticated
      using (bucket_id = 'videos' and (
        (storage.foldername(name))[1] = auth.uid()::text
        or ((storage.foldername(name))[2] = 'sessao' and public.videos_coach_ve_sessao((storage.foldername(name))[1], created_at))
        or ((storage.foldername(name))[2] = 'biblioteca' and public.videos_aluno_ve_biblioteca((storage.foldername(name))[1]))));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'videos_delete_own') then
    create policy videos_delete_own on storage.objects for delete to authenticated
      using (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;
