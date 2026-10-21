-- Notificações push (Web Push, v214). O app inscreve o aparelho (push_salvar) e a edge function `enviar-push`
-- manda: (a) "treino novo do treinador", chamado pelo app do treinador depois de enviar; (b) teste para o próprio
-- aparelho. Sem lembrete diário nem função agendada (decisão do Andre, 21/10: não cobrar o aluno de treinar).
-- Segredos da edge function: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:).
create table if not exists public.push_inscricoes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  ua text,
  tipos jsonb not null default '{"treinador": true}'::jsonb,
  criado_em timestamptz not null default now(),
  ultimo_ok timestamptz,
  falhas int not null default 0
);
create index if not exists push_inscricoes_user_idx on public.push_inscricoes (user_id);
alter table public.push_inscricoes enable row level security;
revoke all on public.push_inscricoes from public, anon, authenticated;

-- O que foi enviado (para limitar a frequência e medir).
create table if not exists public.push_envios (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null,
  ref text not null default '',
  aparelhos int not null default 0,
  criado_em timestamptz not null default now()
);
create index if not exists push_envios_user_idx on public.push_envios (user_id, tipo, criado_em desc);
alter table public.push_envios enable row level security;
revoke all on public.push_envios from public, anon, authenticated;

-- Inscreve (ou atualiza) este aparelho para a pessoa logada. Um aparelho só tem um dono: trocar de conta move a inscrição.
create or replace function public.push_salvar(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null, p_tipos jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not authenticated'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'inscrição inválida'; end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'inscrição inválida'; end if;
  insert into public.push_inscricoes (user_id, endpoint, p256dh, auth, ua, tipos)
  values (me, p_endpoint, p_p256dh, p_auth, left(p_ua, 200), coalesce(p_tipos, '{"treinador": true}'::jsonb))
  on conflict (endpoint) do update set user_id = me, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua,
    tipos = coalesce(p_tipos, public.push_inscricoes.tipos), falhas = 0;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.push_remover(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.push_inscricoes where endpoint = p_endpoint and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- Escolha do que receber (vale para todos os aparelhos da pessoa).
create or replace function public.push_tipos(p_tipos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.push_inscricoes set tipos = jsonb_build_object(
      'treinador', coalesce((p_tipos->>'treinador')::boolean, true))
   where user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;
