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
