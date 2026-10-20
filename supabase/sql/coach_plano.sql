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
