-- Experimento "Ajustar minha semana": liberado pra TODOS por padrão (quem tem Strava conectado continua de fora).
-- O admin pode desligar o "pra todos" no app (Configurações > Admin) e voltar a liberar só por e-mail.
-- Rodar depois de feature_flags.sql. Pode rodar de novo sem problema.

-- Padrão atual: ligado pra todos.
insert into public.app_config (chave, valor, atualizado_em)
values ('ff_ajuste_semana_todos', 'true'::jsonb, now())
on conflict (chave) do nothing;

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
    when p_feature = 'blocos' then true  -- liberado para todos em 20/10 (decisão do Andre)
    when p_feature = 'ajuste_semana' then
      (coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_ajuste_semana_todos'), false)
       or exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature))
      and not exists (select 1 from public.strava_connections where user_id = p_uid)
    else coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_' || p_feature || '_todos'), false)
      or exists (select 1 from public.feature_access where user_id = p_uid and feature = p_feature)
  end;
$$;
revoke all on function public.feature_allowed(uuid, text) from public, anon, authenticated;

-- Admin: lê e muda o "pra todos".
create or replace function public.admin_feature_todos(p_feature text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce((select (valor)::text::boolean from public.app_config where chave = 'ff_' || p_feature || '_todos'), false)
  where public.is_movo_admin();
$$;

create or replace function public.admin_feature_todos_set(p_feature text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if p_feature is null or p_feature not in ('ajuste_semana', 'plano') then raise exception 'feature desconhecida'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('ff_' || p_feature || '_todos', to_jsonb(coalesce(p_on, false)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end;
$$;
revoke all on function public.admin_feature_todos(text) from public, anon;
revoke all on function public.admin_feature_todos_set(text, boolean) from public, anon;
grant execute on function public.admin_feature_todos(text) to authenticated;
grant execute on function public.admin_feature_todos_set(text, boolean) to authenticated;
