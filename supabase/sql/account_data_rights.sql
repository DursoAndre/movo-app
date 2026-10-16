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
