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
