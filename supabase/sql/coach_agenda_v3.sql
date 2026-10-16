-- Agenda do treinador, fase 3: pacotes de aulas com saldo calculado sozinho.
-- Requer coach_agenda_setup.sql e coach_agenda_v2.sql. Idempotente.
-- Sem cobrança nem valores. A observação do pacote não deve guardar dado de saúde.

create table if not exists public.coach_agenda_pacotes (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  pessoa_id uuid not null references public.coach_agenda_pessoas(id) on delete cascade,
  total int not null check (total between 1 and 200),
  validade_dias int check (validade_dias is null or validade_dias between 1 and 730),
  falta_desconta boolean not null default true,
  inicio_em date not null,
  encerrado_em date,
  obs text check (obs is null or char_length(obs) <= 80),
  created_at timestamptz not null default now(),
  constraint coach_agenda_pacotes_fim check (encerrado_em is null or encerrado_em >= inicio_em - 1)
);
create index if not exists coach_agenda_pacotes_pessoa_idx on public.coach_agenda_pacotes (pessoa_id);
alter table public.coach_agenda_pacotes enable row level security;

-- aulas usadas no pacote: presenças (e faltas, se o pacote desconta) dentro do período do pacote
create or replace function public.coach_agenda_pacote_usadas(pk public.coach_agenda_pacotes)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int
    from public.coach_agenda_ocorrencias o
    join public.coach_agenda_itens i on i.id = o.item_id
   where i.pessoa_id = pk.pessoa_id
     and o.data >= pk.inicio_em
     and (pk.encerrado_em is null or o.data <= pk.encerrado_em)
     and (pk.validade_dias is null or o.data <= pk.inicio_em + pk.validade_dias)
     and (o.status = 'feita' or (o.status = 'faltou' and pk.falta_desconta));
$$;

create or replace function public.coach_agenda_listar(p_ini date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg public.coach_agenda_config; itens jsonb; ocs jsonb; pes jsonb;
begin
  perform public.coach_assert_coach();
  if p_ini is null or p_fim is null or p_fim < p_ini or p_fim - p_ini > 62 then
    raise exception 'período inválido';
  end if;
  select * into cfg from public.coach_agenda_config where coach_id = auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'tipo', i.tipo, 'titulo', coalesce(p.nome, i.titulo), 'pessoa_id', i.pessoa_id,
           'hora', to_char(i.hora_inicio, 'HH24:MI'), 'duracao', i.duracao_min,
           'dias', to_jsonb(i.dias_semana), 'data', i.data_unica,
           'inicio_em', i.inicio_em, 'fim_em', i.fim_em) order by i.hora_inicio, i.created_at), '[]'::jsonb)
    into itens
    from public.coach_agenda_itens i left join public.coach_agenda_pessoas p on p.id = i.pessoa_id
   where i.coach_id = auth.uid()
     and ((i.data_unica is not null and i.data_unica between p_ini and p_fim)
       or (i.data_unica is null and i.inicio_em <= p_fim and (i.fim_em is null or i.fim_em >= p_ini)));
  select coalesce(jsonb_agg(jsonb_build_object('item_id', o.item_id, 'data', o.data, 'status', o.status)), '[]'::jsonb)
    into ocs
    from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id
   where i.coach_id = auth.uid() and o.data between p_ini and p_fim;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'nome', p.nome, 'email', p.email, 'telefone', p.telefone, 'link_id', p.link_id,
           'feitas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'feita'),
           'faltas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'faltou'),
           'pacotes', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', k.id, 'total', k.total, 'validade_dias', k.validade_dias, 'falta_desconta', k.falta_desconta,
                       'inicio_em', k.inicio_em, 'encerrado_em', k.encerrado_em, 'obs', k.obs,
                       'usadas', public.coach_agenda_pacote_usadas(k),
                       'vence_em', case when k.validade_dias is null then null else k.inicio_em + k.validade_dias end)
                     order by k.inicio_em desc, k.created_at desc)
                from (select * from public.coach_agenda_pacotes where pessoa_id = p.id order by inicio_em desc, created_at desc limit 12) k
           ), '[]'::jsonb))
         order by lower(p.nome)), '[]'::jsonb)
    into pes
    from public.coach_agenda_pessoas p where p.coach_id = auth.uid();
  return jsonb_build_object(
    'hoje', public.coach_hoje(),
    'itens', itens,
    'ocorrencias', ocs,
    'pessoas', pes,
    'janela', coalesce(cfg.janela, '{}'::jsonb),
    'duracao_padrao', coalesce(cfg.duracao_padrao, 60));
end;
$$;

-- p_id nulo = pacote novo (encerra o pacote aberto do aluno na véspera do início); p_id = ajusta o existente
create or replace function public.coach_agenda_pacote_salvar(
  p_id uuid, p_pessoa uuid, p_total int, p_validade int default null,
  p_falta_desconta boolean default true, p_inicio date default null, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_obs text := nullif(btrim(coalesce(p_obs, '')), ''); v_inicio date; v_id uuid; v_n int;
begin
  perform public.coach_assert_coach();
  if p_total is null or p_total < 1 or p_total > 200 then raise exception 'total de aulas inválido'; end if;
  if p_validade is not null and (p_validade < 1 or p_validade > 730) then raise exception 'validade inválida'; end if;
  if v_obs is not null and char_length(v_obs) > 80 then raise exception 'observação longa demais'; end if;
  if p_id is null then
    if not exists (select 1 from public.coach_agenda_pessoas where id = p_pessoa and coach_id = auth.uid()) then
      raise exception 'aluno não encontrado';
    end if;
    select count(*) into v_n from public.coach_agenda_pacotes where pessoa_id = p_pessoa;
    if v_n >= 100 then raise exception 'limite de pacotes atingido'; end if;
    v_inicio := coalesce(p_inicio, public.coach_hoje());
    update public.coach_agenda_pacotes set encerrado_em = greatest(inicio_em - 1, v_inicio - 1)
     where pessoa_id = p_pessoa and coach_id = auth.uid() and encerrado_em is null;
    insert into public.coach_agenda_pacotes (coach_id, pessoa_id, total, validade_dias, falta_desconta, inicio_em, obs)
    values (auth.uid(), p_pessoa, p_total, p_validade, coalesce(p_falta_desconta, true), v_inicio, v_obs)
    returning id into v_id;
  else
    update public.coach_agenda_pacotes
       set total = p_total, validade_dias = p_validade, falta_desconta = coalesce(p_falta_desconta, true),
           inicio_em = coalesce(p_inicio, inicio_em), obs = v_obs
     where id = p_id and coach_id = auth.uid()
    returning id into v_id;
    if v_id is null then raise exception 'pacote não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.coach_agenda_pacote_encerrar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  update public.coach_agenda_pacotes set encerrado_em = greatest(inicio_em, public.coach_hoje())
   where id = p_id and coach_id = auth.uid() and encerrado_em is null;
end;
$$;

create or replace function public.coach_agenda_pacote_apagar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  delete from public.coach_agenda_pacotes where id = p_id and coach_id = auth.uid();
end;
$$;

do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'coach\_agenda\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
