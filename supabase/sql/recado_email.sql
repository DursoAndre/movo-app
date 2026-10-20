-- Recados por e-mail (aprovado pelo Andre em 20/10/2026, "dentro do limite do Resend") e impacto de apagar uma conta.
-- Rodar depois de painel_gestao.sql. Quem envia é a edge function recado-email (Resend); aqui ficam fila, limites e saída da lista.
-- Limites: o plano grátis do Resend dá 100 e-mails/dia e 3.000/mês para a conta toda (inclui login e avisos),
-- então os recados usam no máximo 80/dia e 2.000/mês. O resto fica na fila e sai ao tocar "Enviar o restante" no dia seguinte.

create table if not exists public.email_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),  -- vai no link "sair da lista" (movoapp.com.br/sair/?t=...)
  sem_recados_em timestamptz);                           -- preenchido = não recebe recados por e-mail
alter table public.email_prefs enable row level security;
revoke all on public.email_prefs from anon, authenticated;

create table if not exists public.recado_emails (
  recado_id bigint not null references public.admin_recados(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  enviado_em timestamptz not null default now(),
  primary key (recado_id, user_id));
alter table public.recado_emails enable row level security;
revoke all on public.recado_emails from anon, authenticated;

create or replace function public._recado_email_cota() returns jsonb
language sql stable security definer set search_path = public as $$
  with b as (select (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') dia,
                    (date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') mes)
  select jsonb_build_object(
    'dia_max', 80, 'mes_max', 2000,
    'hoje', (select count(*) from recado_emails e, b where e.enviado_em >= b.dia),
    'mes', (select count(*) from recado_emails e, b where e.enviado_em >= b.mes))
$$;

-- Quem ainda deve receber este recado por e-mail (público do recado, e-mail confirmado, não saiu da lista, ainda não recebeu).
create or replace function public._recado_email_pendentes(r public.admin_recados)
returns table (user_id uuid, email text, nome text)
language sql stable security definer set search_path = public as $$
  select u.id, u.email::text, nullif(trim(a.display_name), '')
  from auth.users u
  left join app_data a on a.user_id = u.id
  left join email_prefs p on p.user_id = u.id
  where u.email is not null and u.email_confirmed_at is not null
    and p.sem_recados_em is null
    and public._recado_para(r, u.id)
    and not exists (select 1 from recado_emails e where e.recado_id = r.id and e.user_id = u.id)
$$;

-- Edge function: lote a enviar agora (respeita a cota) + texto do recado.
create or replace function public.admin_m_recado_email_fila(p_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r public.admin_recados; c jsonb; cota int; lote jsonb; pend int;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select * into r from admin_recados where id = p_id;
  if not found then raise exception 'recado_nao_encontrado'; end if;
  if not r.ativo or r.valido_ate <= now() then raise exception 'recado_encerrado'; end if;
  c := public._recado_email_cota();
  cota := greatest(0, least((c->>'dia_max')::int - (c->>'hoje')::int, (c->>'mes_max')::int - (c->>'mes')::int));
  insert into email_prefs(user_id) select q.user_id from public._recado_email_pendentes(r) q on conflict do nothing;
  select count(*) into pend from public._recado_email_pendentes(r);
  select coalesce(jsonb_agg(jsonb_build_object('id', q.user_id, 'email', q.email, 'nome', q.nome, 'token', p.token)), '[]'::jsonb) into lote
  from (select * from public._recado_email_pendentes(r) limit cota) q join email_prefs p on p.user_id = q.user_id;
  return jsonb_build_object('recado', jsonb_build_object('titulo', r.titulo, 'texto', r.texto, 'botao_txt', r.botao_txt, 'botao_url', r.botao_url),
                            'pendentes', pend, 'cota', cota, 'lote', lote);
end $$;

-- Edge function: marca quem recebeu (só depois do Resend aceitar).
create or replace function public.admin_m_recado_email_ok(p_id bigint, p_users uuid[]) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  insert into recado_emails(recado_id, user_id) select p_id, x from unnest(p_users) x on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then perform public._admin_registrar('recado_email', null, p_id::text, null, jsonb_build_object('enviados', n)); end if;
  return n;
end $$;

-- Página pública movoapp.com.br/sair/: sai da lista de recados por e-mail (só com o token do link).
create or replace function public.email_sair(p_token uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  update email_prefs set sem_recados_em = coalesce(sem_recados_em, now()) where token = p_token;
  return found;
end $$;

-- Painel: lista de recados com os números de e-mail.
create or replace function public.admin_m_recados() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  c := public._recado_email_cota();
  return jsonb_build_object('cota', c, 'sairam', (select count(*) from email_prefs where sem_recados_em is not null),
    'recados', coalesce((select jsonb_agg(x order by x.criado_em desc) from (
      select a.*, (select count(*) from recado_vistos v where v.recado_id = a.id) as viram,
        (select count(*) from recado_vistos v where v.recado_id = a.id and v.clicou_em is not null) as clicaram,
        (select count(*) from recado_vistos v where v.recado_id = a.id and v.dispensado_em is not null) as dispensaram,
        (select count(*) from recado_emails e where e.recado_id = a.id) as emails,
        case when a.ativo and a.valido_ate > now() then (select count(*) from public._recado_email_pendentes(a)) else 0 end as emails_pendentes
      from admin_recados a order by a.criado_em desc limit 50) x), '[]'::jsonb));
end $$;

-- Painel: o que some junto ao apagar uma conta (mostrado antes de confirmar).
create or replace function public.admin_m_conta_impacto(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'acertos_abertos', (select count(*) from challenge_ledger l left join challenge_acerto_status s on s.ledger_id = l.id
                         where (l.from_user = p_user or l.to_user = p_user) and s.received_at is null and s.forgiven_at is null),
    'desafios_dono', (select count(*) from challenges where owner_id = p_user),
    'alunos', (select count(*) from coach_links where coach_id = p_user and status in ('ativo', 'congelado')),
    'strava', exists (select 1 from strava_connections where user_id = p_user));
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('admin_m_recado_email_fila', 'admin_m_recado_email_ok', 'admin_m_recados', 'admin_m_conta_impacto',
                                                         '_recado_email_cota', '_recado_email_pendentes', 'email_sair')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.proname = 'email_sair' then execute format('grant execute on function %s to anon, authenticated', f.sig);
    elsif f.proname like 'admin_m_%' then execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
