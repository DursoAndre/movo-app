-- Fase 4 (v219): Minhas medidas e fotos (aluno), avaliação e anamnese (treinador).
-- Seguro rodar de novo. Sem "drop" (o conector do Supabase cancela comandos destrutivos).
--
-- Dados de saúde (LGPD, dado sensível): medidas e fotos são do aluno, só ele grava. O treinador
-- só vê com a permissão "ver_medidas" (desligada por padrão) e vínculo ativo. A anamnese é pedida
-- pelo treinador, respondida pelo aluno e só aquele treinador vê; o aluno pode apagar as respostas.

-- 1. Minhas medidas -------------------------------------------------------------------------------
create table if not exists public.user_medidas (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  data date not null,
  peso numeric(5,1) check (peso is null or peso between 20 and 400),
  gordura numeric(4,1) check (gordura is null or gordura between 2 and 70),
  medidas jsonb not null default '{}'::jsonb,           -- cm: cintura, quadril, peito, braco, coxa, panturrilha, abdomen
  nota text check (nota is null or char_length(nota) <= 300),
  fotos text[] not null default '{}' check (cardinality(fotos) <= 3), -- caminhos no bucket "medidas"
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists user_medidas_user_data on public.user_medidas (user_id, data desc);
alter table public.user_medidas enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'user_medidas' and policyname = 'user_medidas_dono') then
    create policy user_medidas_dono on public.user_medidas for all to authenticated
      using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
end $$;
grant select, insert, update, delete on public.user_medidas to authenticated;

-- 2. Permissão nova no vínculo: ver_medidas (ausente = desligada). Mesmas chaves de coach_plano.sql.
create or replace function public.coach_clean_perms(p jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ver_treinos', coalesce((p->>'ver_treinos')::boolean, true),
    'ver_cargas', coalesce((p->>'ver_cargas')::boolean, true),
    'ver_esforco_dor', coalesce((p->>'ver_esforco_dor')::boolean, false),
    'ver_corrida', coalesce((p->>'ver_corrida')::boolean, true),
    'ver_contato', coalesce((p->>'ver_contato')::boolean, false),
    'ajustar_semana', coalesce((p->>'ajustar_semana')::boolean, false),
    'ver_medidas', coalesce((p->>'ver_medidas')::boolean, false)
  );
$$;
revoke execute on function public.coach_clean_perms(jsonb) from public, anon;
grant execute on function public.coach_clean_perms(jsonb) to authenticated;

-- O treinador (vínculo ativo + ver_medidas) pode ver as medidas e as fotos daquele aluno.
create or replace function public.medidas_coach_pode(p_aluno text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coach_links l
    where l.coach_id = auth.uid() and l.student_id::text = p_aluno and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_medidas')::boolean, false));
$$;
revoke execute on function public.medidas_coach_pode(text) from public, anon;
grant execute on function public.medidas_coach_pode(text) to authenticated;

create or replace function public.coach_aluno_medidas(p_link uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_aluno uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select l.student_id into v_aluno from public.coach_links l
    where l.id = p_link and l.coach_id = auth.uid() and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_medidas')::boolean, false);
  if v_aluno is null then return null; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'data', m.data, 'peso', m.peso, 'gordura', m.gordura,
      'medidas', m.medidas, 'nota', m.nota, 'fotos', m.fotos) order by m.data desc)
    from (select * from public.user_medidas where user_id = v_aluno order by data desc limit 60) m), '[]'::jsonb);
end;
$$;
revoke execute on function public.coach_aluno_medidas(uuid) from public, anon;
grant execute on function public.coach_aluno_medidas(uuid) to authenticated;

-- 3. Fotos: bucket PRIVADO "medidas", pasta = user_id, JPEG reduzido no aparelho (lado maior 1280px).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('medidas', 'medidas', false, 716800, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 716800, allowed_mime_types = array['image/jpeg'];
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_insert_own') then
    create policy medidas_insert_own on storage.objects for insert to authenticated
      with check (bucket_id = 'medidas' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_select_own_ou_treinador') then
    create policy medidas_select_own_ou_treinador on storage.objects for select to authenticated
      using (bucket_id = 'medidas' and ((storage.foldername(name))[1] = auth.uid()::text
        or public.medidas_coach_pode((storage.foldername(name))[1])));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_delete_own') then
    create policy medidas_delete_own on storage.objects for delete to authenticated
      using (bucket_id = 'medidas' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

-- 4. Avaliação física feita pelo treinador ------------------------------------------------------
-- O treinador grava (por RPC); o aluno vê as dele em "Minhas medidas", mesmo depois do vínculo acabar.
create table if not exists public.coach_avaliacoes (
  id uuid primary key default gen_random_uuid(),
  link_id uuid not null references public.coach_links(id) on delete cascade,
  coach_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references auth.users(id) on delete cascade,
  data date not null,
  peso numeric(5,1) check (peso is null or peso between 20 and 400),
  gordura numeric(4,1) check (gordura is null or gordura between 2 and 70),
  medidas jsonb not null default '{}'::jsonb,
  testes text check (testes is null or char_length(testes) <= 1000),
  nota text check (nota is null or char_length(nota) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists coach_avaliacoes_link on public.coach_avaliacoes (link_id, data desc);
create index if not exists coach_avaliacoes_aluno on public.coach_avaliacoes (student_id, data desc);
alter table public.coach_avaliacoes enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'coach_avaliacoes' and policyname = 'coach_avaliacoes_ler') then
    create policy coach_avaliacoes_ler on public.coach_avaliacoes for select to authenticated
      using (student_id = auth.uid() or exists (select 1 from public.coach_links l
        where l.id = link_id and l.coach_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado')));
  end if;
end $$;
grant select on public.coach_avaliacoes to authenticated;

-- Medidas aceitas (cm): só números entre 10 e 300 nas chaves conhecidas.
create or replace function public.medidas_limpar(p jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, round(v::numeric, 1)), '{}'::jsonb)
  from jsonb_each_text(coalesce(p, '{}'::jsonb)) as e(k, v)
  where k in ('cintura', 'quadril', 'peito', 'braco', 'coxa', 'panturrilha', 'abdomen')
    and v ~ '^[0-9]+(\.[0-9]+)?$' and v::numeric between 10 and 300;
$$;

create or replace function public.coach_avaliacao_salvar(p_link uuid, p_id uuid, p_data date, p_peso numeric,
  p_gordura numeric, p_medidas jsonb, p_testes text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; v public.coach_avaliacoes;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null then raise exception 'vinculo invalido'; end if;
  if p_data is null or p_data > current_date + 1 then raise exception 'data invalida'; end if;
  if p_id is null then
    insert into public.coach_avaliacoes (link_id, coach_id, student_id, data, peso, gordura, medidas, testes, nota)
    values (l.id, l.coach_id, l.student_id, p_data, p_peso, p_gordura, public.medidas_limpar(p_medidas),
      nullif(left(trim(coalesce(p_testes, '')), 1000), ''), nullif(left(trim(coalesce(p_nota, '')), 1000), ''))
    returning * into v;
  else
    update public.coach_avaliacoes set data = p_data, peso = p_peso, gordura = p_gordura, medidas = public.medidas_limpar(p_medidas),
      testes = nullif(left(trim(coalesce(p_testes, '')), 1000), ''), nota = nullif(left(trim(coalesce(p_nota, '')), 1000), ''), updated_at = now()
    where id = p_id and link_id = l.id returning * into v;
    if v.id is null then raise exception 'avaliacao nao encontrada'; end if;
  end if;
  return to_jsonb(v);
end;
$$;
revoke execute on function public.coach_avaliacao_salvar(uuid, uuid, date, numeric, numeric, jsonb, text, text) from public, anon;
grant execute on function public.coach_avaliacao_salvar(uuid, uuid, date, numeric, numeric, jsonb, text, text) to authenticated;

create or replace function public.coach_avaliacao_apagar(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.coach_avaliacoes a using public.coach_links l
    where a.id = p_id and l.id = a.link_id and l.coach_id = auth.uid() and l.status = 'ativo';
  return found;
end;
$$;
revoke execute on function public.coach_avaliacao_apagar(uuid) from public, anon;
grant execute on function public.coach_avaliacao_apagar(uuid) to authenticated;

-- O aluno vê as avaliações que recebeu, com o nome do treinador.
create or replace function public.minhas_avaliacoes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'data', a.data, 'peso', a.peso, 'gordura', a.gordura,
      'medidas', a.medidas, 'testes', a.testes, 'nota', a.nota, 'coach_nome', coalesce(p.nome_exibicao, 'Treinador')) order by a.data desc)
    from public.coach_avaliacoes a left join public.coach_profiles p on p.user_id = a.coach_id
    where a.student_id = auth.uid()), '[]'::jsonb);
end;
$$;
revoke execute on function public.minhas_avaliacoes() from public, anon;
grant execute on function public.minhas_avaliacoes() to authenticated;

-- 5. Anamnese: o treinador pede, o aluno responde, só aquele treinador vê -------------------------
create table if not exists public.coach_anamneses (
  link_id uuid primary key references public.coach_links(id) on delete cascade,
  coach_id uuid not null references auth.users(id) on delete cascade,
  student_id uuid not null references auth.users(id) on delete cascade,
  pedida_em timestamptz not null default now(),
  respostas jsonb check (respostas is null or pg_column_size(respostas) < 20000),
  respondida_em timestamptz
);
alter table public.coach_anamneses enable row level security; -- sem policies: só pelas RPCs abaixo

create or replace function public.coach_anamnese_pedir(p_link uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null then raise exception 'vinculo invalido'; end if;
  insert into public.coach_anamneses (link_id, coach_id, student_id) values (l.id, l.coach_id, l.student_id)
  on conflict (link_id) do update set pedida_em = now();
  return (select to_jsonb(a) from public.coach_anamneses a where a.link_id = l.id);
end;
$$;
revoke execute on function public.coach_anamnese_pedir(uuid) from public, anon;
grant execute on function public.coach_anamnese_pedir(uuid) to authenticated;

create or replace function public.coach_anamnese(p_link uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return (select jsonb_build_object('pedida_em', a.pedida_em, 'respondida_em', a.respondida_em, 'respostas', a.respostas)
    from public.coach_anamneses a join public.coach_links l on l.id = a.link_id
    where a.link_id = p_link and l.coach_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado'));
end;
$$;
revoke execute on function public.coach_anamnese(uuid) from public, anon;
grant execute on function public.coach_anamnese(uuid) to authenticated;

-- Aluno: pedidos e respostas dele (de vínculos ativos), com o nome do treinador.
create or replace function public.minhas_anamneses()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('link_id', a.link_id, 'pedida_em', a.pedida_em, 'respondida_em', a.respondida_em,
      'respostas', a.respostas, 'coach_nome', coalesce(p.nome_exibicao, 'Treinador')) order by a.pedida_em desc)
    from public.coach_anamneses a join public.coach_links l on l.id = a.link_id
    left join public.coach_profiles p on p.user_id = a.coach_id
    where a.student_id = auth.uid() and l.status in ('ativo', 'pausado', 'congelado')), '[]'::jsonb);
end;
$$;
revoke execute on function public.minhas_anamneses() from public, anon;
grant execute on function public.minhas_anamneses() to authenticated;

-- Responder (p_respostas) ou apagar as respostas (p_respostas null).
create or replace function public.anamnese_responder(p_link uuid, p_respostas jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_respostas is not null and (jsonb_typeof(p_respostas) <> 'object' or pg_column_size(p_respostas) >= 20000) then
    raise exception 'respostas invalidas';
  end if;
  update public.coach_anamneses set respostas = p_respostas, respondida_em = case when p_respostas is null then null else now() end
    where link_id = p_link and student_id = auth.uid();
  return found;
end;
$$;
revoke execute on function public.anamnese_responder(uuid, jsonb) from public, anon;
grant execute on function public.anamnese_responder(uuid, jsonb) to authenticated;

-- 6. Treinador: anamneses respondidas nos últimos 30 dias (para "Para hoje"), com os "sim" do PAR-Q.
create or replace function public.coach_anamneses_resumo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('link_id', a.link_id, 'respondida_em', a.respondida_em, 'sim',
      coalesce((select jsonb_agg(x.i - 1) from jsonb_array_elements(case when jsonb_typeof(a.respostas->'parq') = 'array'
        then a.respostas->'parq' else '[]'::jsonb end) with ordinality as x(v, i) where x.v = 'true'::jsonb), '[]'::jsonb)))
    from public.coach_anamneses a join public.coach_links l on l.id = a.link_id
    where a.coach_id = auth.uid() and l.status = 'ativo' and a.respondida_em > now() - interval '30 days'), '[]'::jsonb);
end;
$$;
revoke execute on function public.coach_anamneses_resumo() from public, anon;
grant execute on function public.coach_anamneses_resumo() to authenticated;

-- 7. LGPD: quando o vínculo acaba, a anamnese é apagada (ninguém mais a vê; não fica guardada sem uso).
-- As avaliações continuam visíveis para o aluno.
create or replace function public.anamnese_apagar_ao_encerrar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('encerrado', 'recusado') and old.status is distinct from new.status then
    delete from public.coach_anamneses where link_id = new.id;
  end if;
  return new;
end;
$$;
revoke execute on function public.anamnese_apagar_ao_encerrar() from public, anon, authenticated;
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'coach_links_apagar_anamnese') then
    create trigger coach_links_apagar_anamnese after update of status on public.coach_links
      for each row execute function public.anamnese_apagar_ao_encerrar();
  end if;
end $$;

-- 8. Push da anamnese (edge function enviar-push, tipo "anamnese"): leituras do service_role.
grant select (link_id, respostas, respondida_em) on public.coach_anamneses to service_role;
grant select (student_label) on public.coach_links to service_role;
