-- Fotos e vídeos: liga/desliga cada recurso pelo painel e mostra o armazenamento usado. Seguro rodar de novo.
-- Requer ai_kill_switch.sql (app_config), admin_identidade.sql, fase4_medidas.sql e fase4_videos.sql.
-- Chaves em app_config: midia_<recurso> = true/false. Recursos:
--   fotos_medidas   fotos de frente/lado/costas em Minhas medidas (bucket medidas)
--   video_aluno     vídeo da execução no comentário da sessão (videos/<uid>/sessao)
--   video_treinador biblioteca de vídeos do treinador (videos/<uid>/biblioteca)
--   foto_checkin    foto no check-in do desafio (fase 5; desligada por decisão do Andre, 22/10)
-- Desligar impede envios novos (app esconde o botão e o storage recusa o upload); o que já existe continua visível.

insert into public.app_config (chave, valor) values
  ('midia_fotos_medidas', 'true'::jsonb),
  ('midia_video_aluno', 'true'::jsonb),
  ('midia_video_treinador', 'true'::jsonb),
  ('midia_foto_checkin', 'false'::jsonb)
on conflict (chave) do nothing;

create or replace function public.midia_ligada(p_recurso text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (valor)::text::boolean from public.app_config where chave = 'midia_' || p_recurso), false);
$$;
revoke all on function public.midia_ligada(text) from public, anon;
grant execute on function public.midia_ligada(text) to authenticated;

-- Para o app: {fotos_medidas: true, ...}
create or replace function public.midia_flags()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(substr(chave, 7), valor), '{}'::jsonb)
  from public.app_config where chave like 'midia\_%';
$$;
revoke all on function public.midia_flags() from public, anon;
grant execute on function public.midia_flags() to authenticated;

-- Painel: chaves + armazenamento por bucket (e por pasta nos vídeos) + quem mais ocupa.
create or replace function public.admin_m_midia()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, storage, auth
as $$
declare r jsonb;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  with o as (
    select bucket_id,
           case when bucket_id = 'videos' then coalesce((storage.foldername(name))[2], '') else '' end as pasta,
           (storage.foldername(name))[1] as dono,
           coalesce((metadata->>'size')::bigint, 0) as bytes,
           created_at
    from storage.objects
  )
  select jsonb_build_object(
    'flags', public.midia_flags(),
    'buckets', coalesce((select jsonb_agg(jsonb_build_object('bucket', bucket_id, 'pasta', pasta, 'arquivos', n, 'bytes', b, 'bytes_7d', b7) order by b desc)
      from (select bucket_id, pasta, count(*) n, sum(bytes) b, sum(bytes) filter (where created_at > now() - interval '7 days') b7 from o group by 1, 2) x), '[]'::jsonb),
    'total_bytes', (select coalesce(sum(bytes), 0) from o),
    'top', coalesce((select jsonb_agg(jsonb_build_object('email', u.email, 'bytes', t.b, 'arquivos', t.n) order by t.b desc)
      from (select dono, sum(bytes) b, count(*) n from o where bucket_id in ('medidas', 'videos') group by 1 order by 2 desc limit 5) t
      left join auth.users u on u.id::text = t.dono), '[]'::jsonb)
  ) into r;
  return r;
end;
$$;
revoke all on function public.admin_m_midia() from public, anon;
grant execute on function public.admin_m_midia() to authenticated;

create or replace function public.admin_midia_set(p_recurso text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  if p_recurso is null or p_recurso not in ('fotos_medidas', 'video_aluno', 'video_treinador', 'foto_checkin') then raise exception 'recurso desconhecido'; end if;
  insert into public.app_config (chave, valor, atualizado_em) values ('midia_' || p_recurso, to_jsonb(coalesce(p_on, false)), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end;
$$;
revoke all on function public.admin_midia_set(text, boolean) from public, anon;
grant execute on function public.admin_midia_set(text, boolean) to authenticated;

-- Storage: upload novo só com o recurso ligado (substitui as políticas de inserção da fase 4).
drop policy if exists medidas_insert_own on storage.objects;
create policy medidas_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'medidas' and (storage.foldername(name))[1] = auth.uid()::text and public.midia_ligada('fotos_medidas'));
drop policy if exists videos_insert_own on storage.objects;
create policy videos_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text
    and (((storage.foldername(name))[2] = 'sessao' and public.midia_ligada('video_aluno'))
      or ((storage.foldername(name))[2] = 'biblioteca' and public.midia_ligada('video_treinador') and public.videos_biblioteca_cabe())));
