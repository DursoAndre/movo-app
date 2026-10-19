-- Experimentos por usuário (feature flags com lista de liberados).
-- Hoje: 'ajuste_semana' (Ajustar minha semana / "Sua semana mudou" com IA).
-- Regra: só quem o admin liberar usa, e quem tem Strava conectado fica de fora (a política da API do Strava
-- proíbe usar dados do Strava em IA). O admin (ardurso@gmail.com) sempre tem acesso, para testar.
-- Rodar uma vez no SQL editor do Supabase. Pode rodar de novo sem problema.

create table if not exists public.feature_access (
  user_id uuid not null references auth.users(id) on delete cascade,
  feature text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, feature)
);
alter table public.feature_access enable row level security;  -- sem policies: só as funções abaixo mexem

-- Interna: decide se um usuário pode usar a feature.
create or replace function public.feature_allowed(p_uid uuid, p_feature text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when p_uid is null then false
    when public.movo_admin_uid(p_uid) then true
    when p_feature = 'ajuste_semana' then
      exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature)
      and not exists (select 1 from public.strava_connections where user_id = p_uid)
    else exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature)
  end;
$$;
revoke all on function public.feature_allowed(uuid, text) from public, anon, authenticated;

-- O app pergunta quais experimentos estão liberados pra pessoa logada.
create or replace function public.my_features()
returns text[]
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(array_agg(f), '{}'::text[])
  from unnest(array['ajuste_semana']) as f
  where public.feature_allowed(auth.uid(), f);
$$;
revoke all on function public.my_features() from public, anon;
grant execute on function public.my_features() to authenticated;

-- Admin: lista quem está liberado (e se o Strava bloqueia).
create or replace function public.admin_feature_list(p_feature text)
returns table (email text, liberado_em timestamptz, tem_strava boolean)
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.email::text, fa.created_at,
         exists (select 1 from public.strava_connections s where s.user_id = fa.user_id)
  from public.feature_access fa
  join auth.users u on u.id = fa.user_id
  where fa.feature = p_feature
    and public.is_movo_admin()
  order by fa.created_at desc;
$$;

-- Admin: libera ou remove uma pessoa pelo e-mail.
create or replace function public.admin_feature_set(p_email text, p_feature text, p_on boolean)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  alvo uuid;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select id into alvo from auth.users where lower(email) = lower(trim(p_email));
  if alvo is null then return 'usuario_nao_encontrado'; end if;
  if p_on then
    insert into public.feature_access (user_id, feature) values (alvo, p_feature) on conflict do nothing;
  else
    delete from public.feature_access where user_id = alvo and feature = p_feature;
  end if;
  return 'ok';
end;
$$;
revoke all on function public.admin_feature_list(text) from public, anon;
revoke all on function public.admin_feature_set(text, text, boolean) from public, anon;
grant execute on function public.admin_feature_list(text) to authenticated;
grant execute on function public.admin_feature_set(text, text, boolean) to authenticated;

-- Trava no servidor: reservar uma geração de 'ajuste_semana' só funciona pra quem está liberado.
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
  if public.movo_admin_uid(uid) then max_per_month := 1000000; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select count(*) into usados from public.plan_generations where user_id = uid and kind = p_kind and created_at >= inicio;
  if usados >= max_per_month then
    return jsonb_build_object('ok', false, 'usados', usados, 'limite', max_per_month);
  end if;
  insert into public.plan_generations (user_id, prova, kind) values (uid, left(p_label, 120), left(p_kind, 40)) returning id into novo;
  return jsonb_build_object('ok', true, 'id', novo, 'usados', usados + 1, 'limite', max_per_month);
end;
$$;
