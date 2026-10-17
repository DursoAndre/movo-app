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
