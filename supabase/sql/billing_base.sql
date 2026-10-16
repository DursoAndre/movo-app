-- Base de planos e cobrança do Movo (v158). DORMENTE: nada muda pra ninguém até o admin ligar as chaves.
-- Tudo no servidor; o app só lê `my_plan()`. Pode rodar de novo sem problema.
-- Rodar depois de feature_flags.sql / feature_flags_todos.sql e coach_setup_v2.sql.
--
-- Duas chaves (app_config), ambas desligadas por padrão:
--   billing_visivel : mostra "Meu plano" e os preços no app pra todo mundo (o admin sempre vê).
--   billing_limites : passa a aplicar os limites do plano (cota mensal de IA e nº de alunos do treinador).
-- Plano grátis = sem linha na tabela. Quem não tem assinatura válida cai no grátis.
-- Pagamento (Asaas) entra depois: o webhook só vai gravar/atualizar linhas em `assinaturas`.

insert into public.app_config (chave, valor, atualizado_em) values
  ('billing_visivel', 'false'::jsonb, now()),
  ('billing_limites', 'false'::jsonb, now())
on conflict (chave) do nothing;

create table if not exists public.assinaturas (
  user_id uuid not null references auth.users(id) on delete cascade,
  linha text not null check (linha in ('aluno', 'treinador')),
  plano text not null,
  ciclo text not null default 'mensal' check (ciclo in ('mensal', 'anual')),
  status text not null default 'ativa' check (status in ('teste', 'ativa', 'atrasada', 'cancelada')),
  origem text not null default 'manual' check (origem in ('manual', 'asaas')),
  gateway_ref text,
  teste_ate timestamptz,
  renova_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  primary key (user_id, linha),
  check ((linha = 'aluno' and plano = 'pro') or (linha = 'treinador' and plano in ('start', 'pro', 'studio')))
);
alter table public.assinaturas enable row level security;  -- sem policies: só as funções abaixo mexem

-- Interna: chave ligada?  ('visivel' | 'limites')
create or replace function public.billing_cfg(p_chave text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (valor)::text::boolean from public.app_config where chave = 'billing_' || p_chave), false);
$$;

-- Interna: plano valendo agora ('gratis' se não houver assinatura válida).
--   teste: até teste_ate | ativa: até renova_em + 3 dias de folga (webhook atrasado) | atrasada: 5 dias de folga
--   cancelada: segue valendo até o fim do período já pago.
create or replace function public.plano_efetivo(p_uid uuid, p_linha text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select a.plano from public.assinaturas a
    where a.user_id = p_uid and a.linha = p_linha
      and (   (a.status = 'teste' and a.teste_ate > now())
           or (a.status = 'ativa' and (a.renova_em is null or a.renova_em > now() - interval '3 days'))
           or (a.status = 'atrasada' and a.renova_em > now() - interval '5 days')
           or (a.status = 'cancelada' and a.renova_em > now()))
  ), 'gratis');
$$;

-- Interna: limites de cada plano (valores do business plan; é aqui que se muda preço/limite).
--   ia_mes: gerações de IA por tipo por mês | alunos: vínculos (convites pendentes + ativos + pausados)
create or replace function public.plano_limites(p_linha text, p_plano text)
returns jsonb
language sql
immutable
as $$
  select case p_linha || ':' || p_plano
    when 'aluno:pro'         then '{"ia_mes": 30}'::jsonb
    when 'treinador:start'   then '{"ia_mes": 10, "alunos": 10}'::jsonb
    when 'treinador:pro'     then '{"ia_mes": 30, "alunos": 30}'::jsonb
    when 'treinador:studio'  then '{"ia_mes": 30, "alunos": 80}'::jsonb
    when 'treinador:gratis'  then '{"ia_mes": 2, "alunos": 3}'::jsonb
    else '{"ia_mes": 2}'::jsonb  -- aluno:gratis
  end;
$$;

-- Interna: cota de IA que vale pra essa pessoa. Com `billing_limites` desligada, segue o valor que o app mandou (como hoje).
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
      (public.plano_limites('aluno', public.plano_efetivo(p_uid, 'aluno'))->>'ia_mes')::int,
      (public.plano_limites('treinador', public.plano_efetivo(p_uid, 'treinador'))->>'ia_mes')::int
    )
  end;
$$;

revoke all on function public.billing_cfg(text) from public, anon, authenticated;
revoke all on function public.plano_efetivo(uuid, text) from public, anon, authenticated;
revoke all on function public.plano_limites(text, text) from public, anon, authenticated;
revoke all on function public.ia_limite_efetivo(uuid, int) from public, anon, authenticated;

-- O app pergunta o plano da pessoa logada (e se deve mostrar planos / aplicar limites).
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
  pa text; pt text;
  ra public.assinaturas; rt public.assinaturas;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  adm := (select email from auth.users where id = uid) = 'ardurso@gmail.com';
  pa := public.plano_efetivo(uid, 'aluno');
  pt := public.plano_efetivo(uid, 'treinador');
  select * into ra from public.assinaturas where user_id = uid and linha = 'aluno';
  select * into rt from public.assinaturas where user_id = uid and linha = 'treinador';
  return jsonb_build_object(
    'visivel', adm or public.billing_cfg('visivel'),
    'limites', public.billing_cfg('limites'),
    'admin', adm,
    'aluno', jsonb_build_object(
      'plano', pa, 'status', ra.status, 'ciclo', ra.ciclo, 'teste_ate', ra.teste_ate, 'renova_em', ra.renova_em,
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

-- Cota de IA: passa a respeitar o plano quando `billing_limites` estiver ligada (desligada = igual a hoje).
create or replace function public.ai_generation_usage(p_kind text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if (select email from auth.users where id = uid) = 'ardurso@gmail.com' then max_per_month := 1000000;
  else max_per_month := public.ia_limite_efetivo(uid, max_per_month); end if;
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  return jsonb_build_object('usados', usados, 'limite', max_per_month, 'por_plano', public.billing_cfg('limites'));
end;
$$;

create or replace function public.reserve_ai_generation(p_kind text, p_label text, max_per_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inicio timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  usados int;
  novo bigint;
  bloqueio text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  bloqueio := public.ai_bloqueio();
  if bloqueio is not null then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', bloqueio, 'usados', 0, 'limite', max_per_month,
      'mensagem', case bloqueio when 'desligada' then 'A IA está temporariamente desligada. Tente mais tarde.' else 'A IA atingiu o limite de uso de hoje. Tente amanhã.' end);
  end if;
  if p_kind = 'ajuste_semana' and not public.feature_allowed(uid, 'ajuste_semana') then
    return jsonb_build_object('ok', false, 'indisponivel', true, 'motivo', 'sem_acesso', 'usados', 0, 'limite', max_per_month,
      'mensagem', 'O ajuste da semana com IA está em teste fechado e ainda não está liberado pra você.');
  end if;
  if (select email from auth.users where id = uid) = 'ardurso@gmail.com' then max_per_month := 1000000;
  else max_per_month := public.ia_limite_efetivo(uid, max_per_month); end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month, 'por_plano', public.billing_cfg('limites'));
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;

-- Convite do treinador: com `billing_limites` ligada, respeita o nº de alunos do plano (desligada = sem teto, como hoje).
create or replace function public.coach_create_invite(p_label text default null)
returns public.coach_links
language plpgsql security definer set search_path = public as $$
declare
  v_code text; v_row public.coach_links; v_try int := 0; v_max int;
begin
  perform public.coach_assert_coach();
  if public.billing_cfg('limites')
     and (select email from auth.users where id = auth.uid()) is distinct from 'ardurso@gmail.com' then
    v_max := (public.plano_limites('treinador', public.plano_efetivo(auth.uid(), 'treinador'))->>'alunos')::int;
    if (select count(*) from public.coach_links
         where coach_id = auth.uid() and status in ('pendente', 'ativo', 'pausado')) >= v_max then
      raise exception 'limite_plano_alunos';
    end if;
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

-- Admin: lê e muda as duas chaves.
create or replace function public.admin_billing_get()
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select jsonb_build_object('visivel', public.billing_cfg('visivel'), 'limites', public.billing_cfg('limites'))
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com';
$$;

create or replace function public.admin_billing_set(p_chave text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if (select email from auth.users where id = auth.uid()) is distinct from 'ardurso@gmail.com' then raise exception 'forbidden'; end if;
  if p_chave not in ('visivel', 'limites') then raise exception 'chave desconhecida'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('billing_' || p_chave, to_jsonb(coalesce(p_on, false)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end;
$$;

-- Admin: dá (ou tira) um plano a alguém pelo e-mail. Serve pra cortesia, beta pago combinado e pra testar.
--   p_plano 'gratis' remove. p_status 'teste' usa p_dias (padrão 14). 'ativa' com p_dias vale por esse tempo; sem p_dias não vence.
create or replace function public.admin_plan_set(
  p_email text, p_linha text, p_plano text,
  p_ciclo text default 'mensal', p_status text default 'ativa', p_dias int default null)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  alvo uuid;
begin
  if (select email from auth.users where id = auth.uid()) is distinct from 'ardurso@gmail.com' then raise exception 'forbidden'; end if;
  select id into alvo from auth.users where lower(email) = lower(trim(p_email));
  if alvo is null then return 'usuario_nao_encontrado'; end if;
  if p_plano = 'gratis' then
    delete from public.assinaturas where user_id = alvo and linha = p_linha;
    return 'ok';
  end if;
  insert into public.assinaturas (user_id, linha, plano, ciclo, status, origem, teste_ate, renova_em)
  values (alvo, p_linha, p_plano, coalesce(p_ciclo, 'mensal'), coalesce(p_status, 'ativa'), 'manual',
          case when p_status = 'teste' then now() + make_interval(days => coalesce(p_dias, 14)) end,
          case when p_status is distinct from 'teste' and p_dias is not null then now() + make_interval(days => p_dias) end)
  on conflict (user_id, linha) do update
    set plano = excluded.plano, ciclo = excluded.ciclo, status = excluded.status, origem = 'manual',
        teste_ate = excluded.teste_ate, renova_em = excluded.renova_em, atualizado_em = now();
  return 'ok';
end;
$$;

create or replace function public.admin_plan_list()
returns table (email text, linha text, plano text, ciclo text, status text, origem text, teste_ate timestamptz, renova_em timestamptz)
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.email::text, a.linha, a.plano, a.ciclo, a.status, a.origem, a.teste_ate, a.renova_em
  from public.assinaturas a
  join auth.users u on u.id = a.user_id
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  order by a.atualizado_em desc;
$$;

revoke all on function public.admin_billing_get() from public, anon;
revoke all on function public.admin_billing_set(text, boolean) from public, anon;
revoke all on function public.admin_plan_set(text, text, text, text, text, int) from public, anon;
revoke all on function public.admin_plan_list() from public, anon;
grant execute on function public.admin_billing_get() to authenticated;
grant execute on function public.admin_billing_set(text, boolean) to authenticated;
grant execute on function public.admin_plan_set(text, text, text, text, text, int) to authenticated;
grant execute on function public.admin_plan_list() to authenticated;
