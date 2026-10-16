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
