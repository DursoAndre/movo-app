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
