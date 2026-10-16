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
    when (select email from auth.users where id = p_uid) = 'ardurso@gmail.com' then 'pro'
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
  adm := (select email from auth.users where id = uid) = 'ardurso@gmail.com';
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
  if (select email from auth.users where id = auth.uid()) is distinct from 'ardurso@gmail.com' then raise exception 'forbidden'; end if;
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
