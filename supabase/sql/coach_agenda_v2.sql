-- Agenda do treinador, fase 2: alunos da agenda, presença (aconteceu/faltou), remarcar,
-- editar "só esta" / "esta e as próximas". Requer coach_agenda_setup.sql. Idempotente.

-- ---------------------------------------------------------------------------
-- Alunos da agenda (com ou sem Movo). Dado do próprio treinador, só ele vê.
-- ---------------------------------------------------------------------------
create table if not exists public.coach_agenda_pessoas (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  email text check (email is null or char_length(email) <= 120),
  telefone text check (telefone is null or telefone ~ '^\d{8,13}$'),
  link_id uuid references public.coach_links(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists coach_agenda_pessoas_coach_idx on public.coach_agenda_pessoas (coach_id);
alter table public.coach_agenda_pessoas enable row level security;

alter table public.coach_agenda_itens
  add column if not exists pessoa_id uuid references public.coach_agenda_pessoas(id) on delete set null;

-- compromissos "particular" da fase 1 (só com nome digitado) viram alunos da agenda
insert into public.coach_agenda_pessoas (coach_id, nome)
select distinct on (i.coach_id, lower(i.titulo)) i.coach_id, i.titulo
  from public.coach_agenda_itens i
 where i.tipo = 'particular' and i.titulo is not null and i.pessoa_id is null
   and not exists (select 1 from public.coach_agenda_pessoas p where p.coach_id = i.coach_id and lower(p.nome) = lower(i.titulo));
update public.coach_agenda_itens i set pessoa_id = p.id, titulo = null
  from public.coach_agenda_pessoas p
 where i.tipo = 'particular' and i.pessoa_id is null and i.titulo is not null
   and p.coach_id = i.coach_id and lower(p.nome) = lower(i.titulo);

-- ---------------------------------------------------------------------------
-- Listar (agora com alunos, contagem de aulas feitas/faltas e título calculado)
-- ---------------------------------------------------------------------------
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
           'faltas', (select count(*) from public.coach_agenda_ocorrencias o join public.coach_agenda_itens i on i.id = o.item_id where i.pessoa_id = p.id and o.status = 'faltou'))
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

-- ---------------------------------------------------------------------------
-- Alunos da agenda: criar/editar e apagar
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_pessoa_salvar(p_id uuid, p_nome text, p_email text default null, p_telefone text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nome text := btrim(coalesce(p_nome, '')); v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
        v_tel text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''); v_id uuid; v_total int;
begin
  perform public.coach_assert_coach();
  if char_length(v_nome) < 1 or char_length(v_nome) > 60 then raise exception 'nome inválido'; end if;
  if v_email is not null and (char_length(v_email) > 120 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'e-mail inválido'; end if;
  if v_tel is not null then
    if left(v_tel, 2) = '55' and char_length(v_tel) > 11 then v_tel := substr(v_tel, 3); end if;
    if v_tel !~ '^\d{10,11}$' then raise exception 'telefone inválido'; end if;
  end if;
  if p_id is null then
    select count(*) into v_total from public.coach_agenda_pessoas where coach_id = auth.uid();
    if v_total >= 300 then raise exception 'limite de alunos na agenda atingido'; end if;
    insert into public.coach_agenda_pessoas (coach_id, nome, email, telefone) values (auth.uid(), v_nome, v_email, v_tel) returning id into v_id;
  else
    update public.coach_agenda_pessoas set nome = v_nome, email = v_email, telefone = v_tel
     where id = p_id and coach_id = auth.uid() returning id into v_id;
    if v_id is null then raise exception 'aluno não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id, 'nome', v_nome, 'email', v_email, 'telefone', v_tel);
end;
$$;

-- apagar o aluno mantém as aulas na agenda, com o nome em texto
create or replace function public.coach_agenda_pessoa_apagar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p public.coach_agenda_pessoas;
begin
  perform public.coach_assert_coach();
  select * into p from public.coach_agenda_pessoas where id = p_id and coach_id = auth.uid();
  if p.id is null then return; end if;
  update public.coach_agenda_itens set titulo = p.nome where pessoa_id = p.id and coach_id = auth.uid();
  delete from public.coach_agenda_pessoas where id = p.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Salvar compromisso (agora com aluno). Troca a assinatura da fase 1.
-- ---------------------------------------------------------------------------
drop function if exists public.coach_agenda_salvar(uuid, text, text, text, int, int[], date, date, date);

create or replace function public.coach_agenda_salvar(
  p_id uuid, p_tipo text, p_titulo text, p_hora text, p_duracao int,
  p_dias int[], p_data date, p_inicio date default null, p_fim date default null, p_pessoa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hora time; v_dias smallint[]; v_titulo text := nullif(btrim(coalesce(p_titulo, '')), ''); v_id uuid;
        v_inicio date; v_total int; v_pessoa uuid := p_pessoa;
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
  if p_tipo <> 'particular' then v_pessoa := null; end if;
  if v_pessoa is not null then
    if not exists (select 1 from public.coach_agenda_pessoas where id = v_pessoa and coach_id = auth.uid()) then raise exception 'aluno não encontrado'; end if;
    v_titulo := null;
  end if;
  v_inicio := coalesce(p_inicio, public.coach_hoje());
  if p_fim is not null and p_fim < v_inicio then raise exception 'fim antes do início'; end if;

  if p_id is null then
    select count(*) into v_total from public.coach_agenda_itens where coach_id = auth.uid();
    if v_total >= 500 then raise exception 'limite de compromissos atingido'; end if;
    insert into public.coach_agenda_itens (coach_id, tipo, titulo, pessoa_id, hora_inicio, duracao_min, dias_semana, data_unica, inicio_em, fim_em)
    values (auth.uid(), p_tipo, v_titulo, v_pessoa, v_hora, p_duracao, v_dias, case when v_dias is null then p_data end, v_inicio, p_fim)
    returning id into v_id;
  else
    update public.coach_agenda_itens
       set tipo = p_tipo, titulo = v_titulo, pessoa_id = v_pessoa, hora_inicio = v_hora, duracao_min = p_duracao,
           dias_semana = v_dias, data_unica = case when v_dias is null then p_data end,
           inicio_em = coalesce(p_inicio, inicio_em), fim_em = p_fim
     where id = p_id and coach_id = auth.uid()
    returning id into v_id;
    if v_id is null then raise exception 'compromisso não encontrado'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

-- o compromisso ocorre nesta data? (ignora exceções)
create or replace function public.coach_agenda_ocorre(i public.coach_agenda_itens, d date)
returns boolean language sql immutable as $$
  select case when i.data_unica is not null then i.data_unica = d
              else d >= i.inicio_em and (i.fim_em is null or d <= i.fim_em) and extract(dow from d)::int = any (i.dias_semana::int[]) end;
$$;

-- ---------------------------------------------------------------------------
-- Presença: aconteceu / faltou (nulo desfaz). Só até hoje.
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_marcar(p_item uuid, p_data date, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; o public.coach_agenda_ocorrencias;
begin
  perform public.coach_assert_coach();
  if p_status is not null and p_status not in ('feita', 'faltou') then raise exception 'status inválido'; end if;
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if not public.coach_agenda_ocorre(i, p_data) then raise exception 'o compromisso não ocorre nesta data'; end if;
  if p_data > public.coach_hoje() then raise exception 'só dá para marcar aulas até hoje'; end if;
  select * into o from public.coach_agenda_ocorrencias where item_id = p_item and data = p_data;
  if o.id is not null and o.status in ('cancelada', 'remarcada') then raise exception 'essa aula foi cancelada ou remarcada'; end if;
  if p_status is null then
    delete from public.coach_agenda_ocorrencias where item_id = p_item and data = p_data and status in ('feita', 'faltou');
  else
    insert into public.coach_agenda_ocorrencias (item_id, data, status) values (p_item, p_data, p_status)
    on conflict (item_id, data) do update set status = excluded.status;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Remarcar uma aula para outra data/hora (a original fica "remarcada")
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_remarcar(p_item uuid, p_data date, p_nova_data date, p_nova_hora text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; v_id uuid; v_total int;
begin
  perform public.coach_assert_coach();
  if p_nova_hora !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'horário inválido'; end if;
  if p_nova_data is null then raise exception 'informe a nova data'; end if;
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if not public.coach_agenda_ocorre(i, p_data) then raise exception 'o compromisso não ocorre nesta data'; end if;
  if i.data_unica is not null then
    update public.coach_agenda_itens set data_unica = p_nova_data, inicio_em = least(inicio_em, p_nova_data), hora_inicio = p_nova_hora::time where id = i.id;
    delete from public.coach_agenda_ocorrencias where item_id = i.id and status in ('feita', 'faltou');
    return jsonb_build_object('id', i.id);
  end if;
  select count(*) into v_total from public.coach_agenda_itens where coach_id = auth.uid();
  if v_total >= 500 then raise exception 'limite de compromissos atingido'; end if;
  insert into public.coach_agenda_ocorrencias (item_id, data, status) values (i.id, p_data, 'remarcada')
  on conflict (item_id, data) do update set status = 'remarcada';
  insert into public.coach_agenda_itens (coach_id, tipo, titulo, pessoa_id, hora_inicio, duracao_min, data_unica, inicio_em)
  values (auth.uid(), i.tipo, i.titulo, i.pessoa_id, p_nova_hora::time, i.duracao_min, p_nova_data, p_nova_data)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Editar só uma data de uma série (cancela a data e cria um compromisso avulso)
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_editar_dia(
  p_item uuid, p_data date, p_tipo text, p_titulo text, p_hora text, p_duracao int, p_pessoa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; v_new jsonb;
begin
  perform public.coach_assert_coach();
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if i.data_unica is not null or not public.coach_agenda_ocorre(i, p_data) then raise exception 'o compromisso não ocorre nesta data'; end if;
  v_new := public.coach_agenda_salvar(null, p_tipo, p_titulo, p_hora, p_duracao, null, p_data, p_data, null, p_pessoa);
  insert into public.coach_agenda_ocorrencias (item_id, data, status) values (i.id, p_data, 'cancelada')
  on conflict (item_id, data) do update set status = 'cancelada';
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Editar "esta e as próximas": a série antiga termina no dia anterior e nasce uma nova daqui pra frente
-- ---------------------------------------------------------------------------
create or replace function public.coach_agenda_dividir(
  p_item uuid, p_a_partir date, p_tipo text, p_titulo text, p_hora text, p_duracao int, p_dias int[], p_pessoa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.coach_agenda_itens; v_new jsonb; v_id uuid;
begin
  perform public.coach_assert_coach();
  select * into i from public.coach_agenda_itens where id = p_item and coach_id = auth.uid();
  if i.id is null then raise exception 'compromisso não encontrado'; end if;
  if i.data_unica is not null then raise exception 'só séries podem ser divididas'; end if;
  if p_a_partir <= i.inicio_em then
    return public.coach_agenda_salvar(i.id, p_tipo, p_titulo, p_hora, p_duracao, p_dias, null, null, i.fim_em, p_pessoa);
  end if;
  v_new := public.coach_agenda_salvar(null, p_tipo, p_titulo, p_hora, p_duracao, p_dias, null, p_a_partir, i.fim_em, p_pessoa);
  v_id := (v_new->>'id')::uuid;
  update public.coach_agenda_ocorrencias set item_id = v_id where item_id = i.id and data >= p_a_partir;
  update public.coach_agenda_itens set fim_em = p_a_partir - 1 where id = i.id;
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões de execução
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
