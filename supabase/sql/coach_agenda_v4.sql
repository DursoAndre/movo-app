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
