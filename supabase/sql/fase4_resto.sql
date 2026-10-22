-- v222: o que ficou da fase 4. Seguro rodar de novo. Sem "drop" (o conector do Supabase cancela comandos destrutivos).
-- 1) Avaliação do treinador com dobras cutâneas (Pollock 3 ou 7) e até 3 fotos.
-- 2) Pedir a anamnese já no convite (vira pedido quando o aluno aceita).
-- 3) Lembrete mensal de medidas (push), opcional, por pessoa.
-- 4) Painel de métricas: linha "Migração".

-- 1. Avaliação: dobras e fotos ---------------------------------------------------------------------
alter table public.coach_avaliacoes add column if not exists dobras jsonb;
alter table public.coach_avaliacoes add column if not exists fotos text[] not null default '{}';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'coach_avaliacoes_fotos_max') then
    alter table public.coach_avaliacoes add constraint coach_avaliacoes_fotos_max check (cardinality(fotos) <= 3);
  end if;
end $$;

-- { protocolo: 3|7, sexo: "m"|"f", idade, mm: { peitoral, axilar, triceps, subescapular, abdomen, suprailiaca, coxa } }
create or replace function public.dobras_limpar(p jsonb)
returns jsonb language plpgsql immutable as $$
declare mm jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return null; end if;
  select coalesce(jsonb_object_agg(k, round(v::numeric, 1)), '{}'::jsonb) into mm
    from jsonb_each_text(case when jsonb_typeof(p->'mm') = 'object' then p->'mm' else '{}'::jsonb end) as e(k, v)
    where k in ('peitoral', 'axilar', 'triceps', 'subescapular', 'abdomen', 'suprailiaca', 'coxa')
      and v ~ '^[0-9]+(\.[0-9]+)?$' and v::numeric between 1 and 90;
  if mm = '{}'::jsonb then return null; end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'protocolo', case when p->>'protocolo' in ('3', '7') then (p->>'protocolo')::int end,
    'sexo', case when p->>'sexo' in ('m', 'f') then p->>'sexo' end,
    'idade', case when p->>'idade' ~ '^[0-9]{1,3}$' and (p->>'idade')::int between 10 and 100 then (p->>'idade')::int end,
    'mm', mm));
end;
$$;

-- Versão nova (com dobras e fotos). A antiga (8 parâmetros) continua para quem ainda não atualizou o app.
create or replace function public.coach_avaliacao_salvar(p_link uuid, p_id uuid, p_data date, p_peso numeric,
  p_gordura numeric, p_medidas jsonb, p_testes text, p_nota text, p_dobras jsonb, p_fotos text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.coach_links; v public.coach_avaliacoes; f text[] := coalesce(p_fotos, '{}'); x text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into l from public.coach_links where id = p_link and coach_id = auth.uid() and status = 'ativo';
  if l.id is null then raise exception 'vinculo invalido'; end if;
  if p_data is null or p_data > current_date + 1 then raise exception 'data invalida'; end if;
  if cardinality(f) > 3 then raise exception 'fotos demais'; end if;
  foreach x in array f loop
    if split_part(x, '/', 1) <> auth.uid()::text then raise exception 'foto invalida'; end if;
  end loop;
  if p_id is null then
    insert into public.coach_avaliacoes (link_id, coach_id, student_id, data, peso, gordura, medidas, testes, nota, dobras, fotos)
    values (l.id, l.coach_id, l.student_id, p_data, p_peso, p_gordura, public.medidas_limpar(p_medidas),
      nullif(left(trim(coalesce(p_testes, '')), 1000), ''), nullif(left(trim(coalesce(p_nota, '')), 1000), ''),
      public.dobras_limpar(p_dobras), f)
    returning * into v;
  else
    update public.coach_avaliacoes set data = p_data, peso = p_peso, gordura = p_gordura, medidas = public.medidas_limpar(p_medidas),
      testes = nullif(left(trim(coalesce(p_testes, '')), 1000), ''), nota = nullif(left(trim(coalesce(p_nota, '')), 1000), ''),
      dobras = public.dobras_limpar(p_dobras), fotos = f, updated_at = now()
    where id = p_id and link_id = l.id returning * into v;
    if v.id is null then raise exception 'avaliacao nao encontrada'; end if;
  end if;
  return to_jsonb(v);
end;
$$;
revoke execute on function public.coach_avaliacao_salvar(uuid, uuid, date, numeric, numeric, jsonb, text, text, jsonb, text[]) from public, anon;
grant execute on function public.coach_avaliacao_salvar(uuid, uuid, date, numeric, numeric, jsonb, text, text, jsonb, text[]) to authenticated;

-- O aluno vê as avaliações que recebeu, agora com dobras e fotos.
create or replace function public.minhas_avaliacoes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'data', a.data, 'peso', a.peso, 'gordura', a.gordura,
      'medidas', a.medidas, 'testes', a.testes, 'nota', a.nota, 'dobras', a.dobras, 'fotos', a.fotos,
      'coach_nome', coalesce(p.nome_exibicao, 'Treinador')) order by a.data desc)
    from public.coach_avaliacoes a left join public.coach_profiles p on p.user_id = a.coach_id
    where a.student_id = auth.uid()), '[]'::jsonb);
end;
$$;
revoke execute on function public.minhas_avaliacoes() from public, anon;
grant execute on function public.minhas_avaliacoes() to authenticated;

-- Fotos da avaliação ficam na pasta do treinador (<coach>/aval/<pose>-<id>.jpg, bucket "medidas").
-- O aluno avaliado pode ver as fotos das avaliações dele.
create or replace function public.medidas_aval_aluno_pode(p_nome text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coach_avaliacoes a where a.student_id = auth.uid() and p_nome = any(a.fotos));
$$;
revoke execute on function public.medidas_aval_aluno_pode(text) from public, anon;
grant execute on function public.medidas_aval_aluno_pode(text) to authenticated;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'medidas_select_aval_aluno') then
    create policy medidas_select_aval_aluno on storage.objects for select to authenticated
      using (bucket_id = 'medidas' and public.medidas_aval_aluno_pode(name));
  end if;
end $$;

-- 2. Anamnese pedida no convite ----------------------------------------------------------------------
alter table public.coach_links add column if not exists pedir_anamnese boolean not null default false;

create or replace function public.coach_convite_anamnese(p_link uuid, p_on boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.coach_links set pedir_anamnese = coalesce(p_on, false)
    where id = p_link and coach_id = auth.uid() and status = 'pendente';
  return found;
end;
$$;
revoke execute on function public.coach_convite_anamnese(uuid, boolean) from public, anon;
grant execute on function public.coach_convite_anamnese(uuid, boolean) to authenticated;

create or replace function public.anamnese_pedir_ao_aceitar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'ativo' and old.status = 'pendente' and new.pedir_anamnese and new.student_id is not null then
    insert into public.coach_anamneses (link_id, coach_id, student_id) values (new.id, new.coach_id, new.student_id)
    on conflict (link_id) do nothing;
  end if;
  return new;
end;
$$;
revoke execute on function public.anamnese_pedir_ao_aceitar() from public, anon, authenticated;
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'coach_links_pedir_anamnese') then
    create trigger coach_links_pedir_anamnese after update of status on public.coach_links
      for each row execute function public.anamnese_pedir_ao_aceitar();
  end if;
end $$;

-- 3. Lembrete mensal de medidas ------------------------------------------------------------------------
-- Ligado quando a pessoa registra a 1ª medida (o app pergunta na hora se mantém ou desativa).
-- Sai 1 aviso quando o último registro tem 30+ dias, no máximo 1 a cada 27 dias, e para depois de 3 avisos sem registro novo.
create table if not exists public.user_lembretes (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  medidas boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.user_lembretes enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'user_lembretes' and policyname = 'user_lembretes_dono') then
    create policy user_lembretes_dono on public.user_lembretes for all to authenticated
      using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
end $$;
grant select, insert, update on public.user_lembretes to authenticated;

create or replace function public.push_medidas_devidos()
returns table (user_id uuid, dias int) language sql stable security definer set search_path = public as $$
  select l.user_id, ((now() at time zone 'America/Sao_Paulo')::date - max(m.data))::int
  from public.user_lembretes l join public.user_medidas m on m.user_id = l.user_id
  where l.medidas
    and exists (select 1 from public.push_inscricoes i where i.user_id = l.user_id)
    and not exists (select 1 from public.push_envios e where e.user_id = l.user_id and e.tipo = 'medidas'
      and e.criado_em > now() - interval '27 days')
  group by l.user_id
  having max(m.data) <= (now() at time zone 'America/Sao_Paulo')::date - 30
    and (select count(*) from public.push_envios e where e.user_id = l.user_id and e.tipo = 'medidas'
      and e.criado_em > max(m.data)::timestamptz + interval '1 day') < 3;
$$;
revoke all on function public.push_medidas_devidos() from public, anon, authenticated;
grant execute on function public.push_medidas_devidos() to service_role;

-- Todo dia às 10h de Brasília (13h UTC); a edge function só manda para quem está na lista acima.
select cron.unschedule('push-medidas-diario') where exists (select 1 from cron.job where jobname = 'push-medidas-diario');
select cron.schedule('push-medidas-diario', '0 13 * * *', $job$
  select net.http_post(
    url := 'https://wgdhjkebfvcmgokxscvb.supabase.co/functions/v1/enviar-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
    body := '{"tipo":"medidas"}'::jsonb
  );
$job$);

-- 4. Painel: Migração (últimos 90 dias) --------------------------------------------------------------
-- Por treinador: dias entre o 1º convite e o 3º aluno com treino enviado. Anamnese respondida em até 48 h.
-- Importações de histórico: quantas usaram CSV, a média de exercícios "novos" (sem par no catálogo) e medidas importadas.
create or replace function public.admin_m_migracao() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare ex uuid[] := public._m_excl(); r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with conv as (
    select coach_id, min(created_at) primeiro from public.coach_links where coach_id <> all(ex) group by coach_id
    having min(created_at) > now() - interval '90 days'),
  ficha as (
    select l.coach_id, l.student_id, min(a.created_at) em from public.coach_assignments a join public.coach_links l on l.id = a.link_id
    where l.student_id is not null and l.coach_id in (select coach_id from conv) group by 1, 2),
  ord as (select coach_id, em, row_number() over (partition by coach_id order by em) n from ficha),
  tr as (
    select c.coach_id, c.primeiro, coalesce(p.nome_exibicao, 'Treinador') nome,
      (select count(*) from ficha f where f.coach_id = c.coach_id) alunos,
      (select o.em from ord o where o.coach_id = c.coach_id and o.n = 3) terceiro
    from conv c left join public.coach_profiles p on p.user_id = c.coach_id),
  ev as (select name, props from public.app_events where created_at > now() - interval '90 days' and user_id <> all(ex)
    and name in ('coach_anamnese_pedida', 'anamnese_respondida', 'hist_import_aplicado', 'hist_import_medidas'))
  select jsonb_build_object(
    'treinadores', coalesce((select jsonb_agg(jsonb_build_object('nome', nome, 'primeiro', primeiro, 'alunos', alunos,
        'dias', case when terceiro is null then null else round(extract(epoch from terceiro - primeiro) / 86400.0, 1) end) order by primeiro desc) from tr), '[]'::jsonb),
    'anamnese', (select jsonb_build_object(
        'pedidas', count(*) filter (where name = 'coach_anamnese_pedida' and coalesce(props->>'lembrete', 'false') <> 'true'),
        'respondidas', count(*) filter (where name = 'anamnese_respondida' and coalesce(props->>'editando', 'false') <> 'true'),
        'em_48h', count(*) filter (where name = 'anamnese_respondida' and coalesce(props->>'editando', 'false') <> 'true'
          and (props->>'horas_desde_pedido') ~ '^[0-9.]+$' and (props->>'horas_desde_pedido')::numeric <= 48)) from ev),
    'importacoes', (select jsonb_build_object(
        'total', count(*) filter (where name = 'hist_import_aplicado'),
        'csv', count(*) filter (where name = 'hist_import_aplicado' and coalesce(props->>'app', '') <> ''),
        'novos_ex_media', round(avg((props->>'novos_ex')::numeric) filter (where name = 'hist_import_aplicado' and (props->>'novos_ex') ~ '^[0-9]+$'), 1),
        'novos_ex_csv', round(avg((props->>'novos_ex')::numeric) filter (where name = 'hist_import_aplicado' and coalesce(props->>'app', '') <> '' and (props->>'novos_ex') ~ '^[0-9]+$'), 1),
        'medidas', coalesce(sum((props->>'n')::int) filter (where name = 'hist_import_medidas' and (props->>'n') ~ '^[0-9]+$'), 0),
        'medidas_vezes', count(*) filter (where name = 'hist_import_medidas')) from ev)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_m_migracao() from public, anon;
grant execute on function public.admin_m_migracao() to authenticated;
