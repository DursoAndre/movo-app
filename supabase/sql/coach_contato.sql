-- Telefone opcional de qualquer usuário (fase 4c da agenda do treinador).
-- Finalidade: contato do treinador (se houver vínculo e permissão "ver_contato") e avisos da conta.
-- Nunca marketing. Quem preenche pode apagar a qualquer momento. Idempotente.
-- Requer coach_setup.sql. Rode ANTES de reaplicar account_data_rights.sql.

create table if not exists public.user_contact (
  user_id uuid primary key references auth.users(id) on delete cascade,
  telefone text not null check (telefone ~ '^\d{10,11}$'),
  atualizado_em timestamptz not null default now()
);
alter table public.user_contact enable row level security;   -- sem políticas: só pelas funções abaixo

-- o próprio telefone (ou nulo)
create or replace function public.contact_get()
returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return (select telefone from public.user_contact where user_id = auth.uid());
end;
$$;

-- grava ou, com valor vazio, apaga o próprio telefone. Guarda só dígitos, com DDD, sem o 55.
create or replace function public.contact_set(p_telefone text)
returns text language plpgsql security definer set search_path = public as $$
declare v_tel text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_tel is null then
    delete from public.user_contact where user_id = auth.uid();
    return null;
  end if;
  if left(v_tel, 2) = '55' and char_length(v_tel) > 11 then v_tel := substr(v_tel, 3); end if;
  if v_tel !~ '^\d{10,11}$' then raise exception 'telefone inválido: use DDD + número'; end if;
  insert into public.user_contact (user_id, telefone, atualizado_em) values (auth.uid(), v_tel, now())
  on conflict (user_id) do update set telefone = excluded.telefone, atualizado_em = now();
  return v_tel;
end;
$$;

-- permissão nova no vínculo. Ausente = desligada (vínculos antigos nunca consentiram com isso).
create or replace function public.coach_clean_perms(p jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ver_treinos', coalesce((p->>'ver_treinos')::boolean, true),
    'ver_cargas', coalesce((p->>'ver_cargas')::boolean, true),
    'ver_esforco_dor', coalesce((p->>'ver_esforco_dor')::boolean, false),
    'ver_corrida', coalesce((p->>'ver_corrida')::boolean, true),
    'ver_contato', coalesce((p->>'ver_contato')::boolean, false)
  );
$$;

-- treinador: telefone do aluno, só com vínculo ativo e permissão ligada pelo aluno
create or replace function public.coach_aluno_contato(p_link uuid)
returns text language plpgsql security definer set search_path = public as $$
declare l public.coach_links;
begin
  perform public.coach_assert_coach();
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null or l.student_id is null then return null; end if;
  if not coalesce((l.permissions->>'ver_contato')::boolean, false) then return null; end if;
  return (select telefone from public.user_contact where user_id = l.student_id);
end;
$$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('contact_get', 'contact_set', 'coach_aluno_contato', 'coach_clean_perms')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
