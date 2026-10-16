-- Compartilhamento de relatórios entre contas do Movo (ex: aluno -> fisio).
-- O aluno escolhe o e-mail de quem pode ver, e quais categorias de dado
-- ficam visíveis. A filtragem por categoria acontece aqui dentro do banco
-- (não é só esconder aba no app) — get_shared_report só devolve o que o
-- aluno liberou, e só pra quem ele liberou.

create table public.report_shares (
  id bigint generated always as identity primary key,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  owner_email text not null,
  viewer_email text not null,
  share_frequencia boolean not null default true,
  share_carga boolean not null default true,
  share_peso_notas boolean not null default false,
  share_treinos boolean not null default false,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (owner_user_id, viewer_email)
);

alter table public.report_shares enable row level security;

grant select, insert, update, delete on public.report_shares to authenticated;

-- O dono (aluno) vê/gerencia livremente os compartilhamentos que ele criou.
create policy report_shares_owner_all on public.report_shares
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

-- Quem recebeu acesso (fisio) só consegue ver a linha em que o e-mail dele
-- bate com viewer_email, e só enquanto não foi revogado.
create policy report_shares_viewer_select on public.report_shares
  for select using (
    revoked_at is null
    and viewer_email = (select email from auth.users where id = auth.uid())
  );

-- Devolve os dados do aluno pro fisio, filtrados pelas categorias que ele
-- liberou. security definer: roda com privilégio elevado, mas só devolve
-- algo se existir um compartilhamento ativo pro e-mail de quem chamou —
-- checado aqui dentro, não só no app.
create or replace function public.get_shared_report(p_owner_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  caller_email text;
  share_row public.report_shares%rowtype;
  ad public.app_data%rowtype;
  found_ad boolean;
  filtered_sessions jsonb := '{}'::jsonb;
  date_key text;
  session_val jsonb;
  log_val jsonb;
  new_log jsonb;
  item_key text;
  item_val jsonb;
  new_item jsonb;
  ex_key text;
  ex_val jsonb;
  new_ex jsonb;
  new_treino_log jsonb;
  min_treinos jsonb;
begin
  select email into caller_email from auth.users where id = auth.uid();
  if caller_email is null then
    raise exception 'not_authenticated';
  end if;

  select * into share_row from public.report_shares
    where owner_user_id = p_owner_user_id
      and viewer_email = caller_email
      and revoked_at is null
    limit 1;
  if not found then
    raise exception 'not_shared';
  end if;

  select * into ad from public.app_data where user_id = p_owner_user_id;
  found_ad := found;
  if not found_ad then
    ad.sessions := '{}'::jsonb;
    ad.treinos := '[]'::jsonb;
    ad.atividades := '[]'::jsonb;
  end if;

  if share_row.share_treinos then
    min_treinos := coalesce(ad.treinos, '[]'::jsonb);
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', t->>'id',
      'nome', t->>'nome',
      'blocos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'nome', b->>'nome',
          'exercicios', (
            select coalesce(jsonb_agg(jsonb_build_object('id', ex->>'id', 'nome', ex->>'nome')), '[]'::jsonb)
            from jsonb_array_elements(coalesce(b->'exercicios', '[]'::jsonb)) ex
          )
        )), '[]'::jsonb)
        from jsonb_array_elements(coalesce(t->'blocos', '[]'::jsonb)) b
      )
    )), '[]'::jsonb)
    into min_treinos
    from jsonb_array_elements(coalesce(ad.treinos, '[]'::jsonb)) t;
  end if;

  for date_key, session_val in select * from jsonb_each(coalesce(ad.sessions, '{}'::jsonb))
  loop
    new_log := '{}'::jsonb;
    if share_row.share_frequencia then
      log_val := coalesce(session_val->'log', '{}'::jsonb);
      for item_key, item_val in select * from jsonb_each(log_val)
      loop
        if item_key like 'treino:%' then
          new_treino_log := '{}'::jsonb;
          for ex_key, ex_val in select * from jsonb_each(item_val)
          loop
            new_ex := jsonb_build_object('status', ex_val->'status');
            if share_row.share_peso_notas then
              new_ex := new_ex || jsonb_build_object('sets', coalesce(ex_val->'sets', '[]'::jsonb));
              if ex_val ? 'comentario' then
                new_ex := new_ex || jsonb_build_object('comentario', ex_val->'comentario');
              end if;
            end if;
            new_treino_log := new_treino_log || jsonb_build_object(ex_key, new_ex);
          end loop;
          new_log := new_log || jsonb_build_object(item_key, new_treino_log);
        else
          new_item := jsonb_build_object('status', item_val->'status');
          if share_row.share_peso_notas and item_val ? 'comentario' then
            new_item := new_item || jsonb_build_object('comentario', item_val->'comentario');
          end if;
          new_log := new_log || jsonb_build_object(item_key, new_item);
        end if;
      end loop;
    end if;

    filtered_sessions := filtered_sessions || jsonb_build_object(
      date_key,
      jsonb_build_object(
        'log', new_log,
        'cargas', case when share_row.share_carga then coalesce(session_val->'cargas', '{}'::jsonb) else '{}'::jsonb end,
        'extras', case when share_row.share_frequencia then coalesce(session_val->'extras', '[]'::jsonb) else '[]'::jsonb end
      )
    );
  end loop;

  return jsonb_build_object(
    'owner_email', share_row.owner_email,
    'sessions', filtered_sessions,
    'treinos', min_treinos,
    'atividades', coalesce(ad.atividades, '[]'::jsonb),
    'flags', jsonb_build_object(
      'frequencia', share_row.share_frequencia,
      'carga', share_row.share_carga,
      'peso_notas', share_row.share_peso_notas,
      'treinos', share_row.share_treinos
    )
  );
end;
$$;

grant execute on function public.get_shared_report(uuid) to authenticated;
