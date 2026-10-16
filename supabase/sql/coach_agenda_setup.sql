-- Agenda do treinador (fase 1): compromissos (aula particular, coletiva, treino próprio, outros),
-- recorrência semanal, exceções por dia e janela de trabalho (horário livre = janela - compromissos).
-- Requer coach_setup.sql e coach_setup_v2.sql. Idempotente (pode rodar de novo).
-- Horários são locais (America/Sao_Paulo), sem fuso: a agenda é presencial.

-- ---------------------------------------------------------------------------
-- Tabelas (RLS ligado, sem políticas: tudo passa pelas funções abaixo)
-- ---------------------------------------------------------------------------
create table if not exists public.coach_agenda_itens (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('particular', 'coletiva', 'treino_proprio', 'outro')),
  titulo text check (titulo is null or char_length(titulo) <= 60),
  hora_inicio time not null,
  duracao_min int not null check (duracao_min between 5 and 600),
  dias_semana smallint[],            -- 0=domingo ... 6=sábado (recorrente)
  data_unica date,                   -- compromisso de um dia só
  inicio_em date not null,           -- recorrência vale a partir daqui
  fim_em date,                       -- e até aqui (inclusive); nulo = sem fim
  created_at timestamptz not null default now(),
  constraint coach_agenda_itens_recorrencia check (
    (data_unica is not null and dias_semana is null)
    or (data_unica is null and dias_semana is not null and cardinality(dias_semana) between 1 and 7)
  ),
  constraint coach_agenda_itens_fim check (fim_em is null or fim_em >= inicio_em)
);
create index if not exists coach_agenda_itens_coach_idx on public.coach_agenda_itens (coach_id);
alter table public.coach_agenda_itens enable row level security;

-- exceções de uma data (cancelada agora; feita/faltou/remarcada nas próximas fases)
create table if not exists public.coach_agenda_ocorrencias (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.coach_agenda_itens(id) on delete cascade,
  data date not null,
  status text not null check (status in ('cancelada', 'feita', 'faltou', 'remarcada')),
  created_at timestamptz not null default now(),
  unique (item_id, data)
);
alter table public.coach_agenda_ocorrencias enable row level security;

create table if not exists public.coach_agenda_config (
  coach_id uuid primary key references auth.users(id) on delete cascade,
  janela jsonb not null default '{}'::jsonb,   -- {"1":[["06:00","12:00"],["16:00","21:00"]], ...} chave = dia da semana
  duracao_padrao int not null default 60 check (duracao_padrao between 5 and 600),
  updated_at timestamptz not null default now()
);
alter table public.coach_agenda_config enable row level security;

-- ---------------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_listar(p_ini date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg public.coach_agenda_config; itens jsonb; ocs jsonb;
begin
  perform public.coach_assert_coach();
  if p_ini is null or p_fim is null or p_fim < p_ini or p_fim - p_ini > 62 then
    raise exception 'período inválido';
  end if;
  select * into cfg from public.coach_agenda_config where coach_id = auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'tipo', i.tipo, 'titulo', i.titulo,
           'hora', to_char(i.hora_inicio, 'HH24:MI'), 'duracao', i.duracao_min,
           'dias', to_jsonb(i.dias_semana), 'data', i.data_unica,
           'inicio_em', i.inicio_em, 'fim_em', i.fim_em) order by i.hora_inicio, i.created_at), '[]'::jsonb)
    into itens
    from public.coach_agenda_itens i
   where i.coach_id = auth.uid()
     and ((i.data_unica is not null and i.data_unica between p_ini and p_fim)
       or (i.data_unica is null and i.inicio_em <= p_fim and (i.fim_em is null or i.fim_em >= p_ini)));
  select coalesce(jsonb_agg(jsonb_build_object('item_id', o.item_id, 'data', o.data, 'status', o.status)), '[]'::jsonb)
    into ocs
    from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id
   where i.coach_id = auth.uid() and o.data between p_ini and p_fim;
  return jsonb_build_object(
    'hoje', public.coach_hoje(),
    'itens', itens,
    'ocorrencias', ocs,
    'janela', coalesce(cfg.janela, '{}'::jsonb),
    'duracao_padrao', coalesce(cfg.duracao_padrao, 60));
end;
$$;

create or replace function public.coach_agenda_salvar(
  p_id uuid, p_tipo text, p_titulo text, p_hora text, p_duracao int,
  p_dias int[], p_data date, p_inicio date default null, p_fim date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hora time; v_dias smallint[]; v_titulo text := nullif(btrim(coalesce(p_titulo, '')), ''); v_id uuid;
        v_inicio date; v_total int;
begin
  perform public.coach_assert_coach();
  if p_tipo not in ('particular', 'coletiva', 'treino_proprio', 'outro') then raise exception 'tipo inválido'; end if;
  if v_titulo is not null and char_length(v_titulo) > 60 then raise exception 'título longo demais'; end if;
  if p_hora !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'horário inválido'; end if;
  v_hora := p_hora::time;
  if p_duracao is null or p_duracao < 5 or p_duracao > 600 then raise exception 'duração inválida'; end if;
  if p_dias is not null and cardinality(p_dias) > 0 then
    if exists (select 1 from unnest(p_dias) d where d < 0 or d > 6) then raise exception 'dia da semana inválido'; end if;
    select array_agg(distinct d::smallint order by d::smallint) into v_dias from unnest(p_dias) d;
    if p_data is not null then raise exception 'use dias ou data, não os dois'; end if;
  elsif p_data is null then
    raise exception 'informe a data ou os dias da semana';
  end if;
  v_inicio := coalesce(p_inicio, public.coach_hoje());
  if p_fim is not null and p_fim < v_inicio then raise exception 'fim antes do início'; end if;

  if p_id is null then
    select count(*) into v_total from public.coach_agenda_itens where coach_id = auth.uid();
    if v_total >= 500 then raise exception 'limite de compromissos atingido'; end if;
    insert into public.coach_agenda_itens (coach_id, tipo, titulo, hora_inicio, duracao_min, dias_semana, data_unica, inicio_em, fim_em)
    values (auth.uid(), p_tipo, v_titulo, v_hora, p_duracao, v_dias, case when v_dias is null then p_data end, v_inicio, p_fim)
    returning id into v_id;
  else
    update public.coach_agenda_itens
       set tipo = p_tipo, titulo = v_titulo, hora_inicio = v_hora, duracao_min = p_duracao,
           dias_semana = v_dias, data_unica = case when v_dias is null then p_data end,
           inicio_em = coalesce(p_inicio, inicio_em), fim_em = p_fim
     where id = p_id and coach_id = auth.uid()
    returning id into v_id;
    if v_id is null then raise exception 'compromisso não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.coach_agenda_apagar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  delete from public.coach_agenda_itens where id = p_id and coach_id = auth.uid();
end;
$$;

-- "só esta": cancela uma data de um compromisso recorrente
create or replace function public.coach_agenda_cancelar_dia(p_item uuid, p_data date)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.coach_assert_coach();
  if not exists (select 1 from public.coach_agenda_itens where id = p_item and coach_id = auth.uid()) then
    raise exception 'compromisso não encontrado';
  end if;
  insert into public.coach_agenda_ocorrencias (item_id, data, status) values (p_item, p_data, 'cancelada')
  on conflict (item_id, data) do update set status = 'cancelada';
end;
$$;

-- "esta e as próximas": a série termina no dia anterior (e some se ainda nem tinha começado)
create or replace function public.coach_agenda_encerrar_serie(p_item uuid, p_a_partir date)
returns void language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens;
begin
  perform public.coach_assert_coach();
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if p_a_partir <= i.inicio_em then
    delete from public.coach_agenda_itens where id = i.id;
  else
    update public.coach_agenda_itens set fim_em = p_a_partir - 1 where id = i.id;
  end if;
end;
$$;

create or replace function public.coach_agenda_config_salvar(p_janela jsonb, p_duracao int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; faixa jsonb; v_ini time; v_fim time; v_norm jsonb := '{}'::jsonb; v_lista jsonb;
begin
  perform public.coach_assert_coach();
  if p_duracao is null or p_duracao < 5 or p_duracao > 600 then raise exception 'duração inválida'; end if;
  if p_janela is null or jsonb_typeof(p_janela) <> 'object' then raise exception 'janela inválida'; end if;
  for k in select jsonb_object_keys(p_janela) loop
    if k !~ '^[0-6]$' then raise exception 'dia da semana inválido'; end if;
    if jsonb_typeof(p_janela->k) <> 'array' or jsonb_array_length(p_janela->k) > 6 then raise exception 'faixas inválidas'; end if;
    v_lista := '[]'::jsonb;
    for faixa in select * from jsonb_array_elements(p_janela->k) loop
      if jsonb_typeof(faixa) <> 'array' or jsonb_array_length(faixa) <> 2
         or (faixa->>0) !~ '^([01]\d|2[0-3]):[0-5]\d$' or (faixa->>1) !~ '^([01]\d|2[0-3]):[0-5]\d$' then
        raise exception 'faixa inválida';
      end if;
      v_ini := (faixa->>0)::time; v_fim := (faixa->>1)::time;
      if v_fim <= v_ini then raise exception 'faixa termina antes de começar'; end if;
      v_lista := v_lista || jsonb_build_array(faixa);
    end loop;
    v_norm := v_norm || jsonb_build_object(k, v_lista);
  end loop;
  insert into public.coach_agenda_config (coach_id, janela, duracao_padrao, updated_at)
  values (auth.uid(), v_norm, p_duracao, now())
  on conflict (coach_id) do update set janela = excluded.janela, duracao_padrao = excluded.duracao_padrao, updated_at = now();
  return jsonb_build_object('janela', v_norm, 'duracao_padrao', p_duracao);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões de execução (mesmo padrão das demais funções coach_*)
-- ---------------------------------------------------------------------------
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
