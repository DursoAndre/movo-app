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
