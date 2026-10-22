-- Fase 4 (v219): vídeos. Seguro rodar de novo. Sem "drop" (o conector do Supabase cancela comandos destrutivos).
--
-- Bucket PRIVADO "videos", compactado no aparelho antes de subir:
--   <aluno>/sessao/...     vídeo da execução no comentário da sessão (até 30 s). O treinador vê só com
--                          vínculo ativo, "ver_treinos" e "ver_cargas" ligados e por 90 dias. O app do aluno
--                          apaga os arquivos com mais de 90 dias e os de quando não há mais treinador.
--   <treinador>/biblioteca/...  vídeo próprio do treinador (até 60 s), sem expirar, até 20 por treinador.
--                          Os alunos com vínculo ativo veem. A lista fica em coach_videos.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', false, 12582912, array['video/mp4', 'video/webm', 'video/quicktime'])
on conflict (id) do update set public = false, file_size_limit = 12582912, allowed_mime_types = array['video/mp4', 'video/webm', 'video/quicktime'];

create table if not exists public.coach_videos (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exercicio text not null check (char_length(exercicio) between 1 and 80),
  path text not null check (char_length(path) <= 200),
  dur int check (dur is null or dur between 1 and 61),
  created_at timestamptz not null default now()
);
create index if not exists coach_videos_coach on public.coach_videos (coach_id, created_at desc);
alter table public.coach_videos enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'coach_videos' and policyname = 'coach_videos_dono') then
    create policy coach_videos_dono on public.coach_videos for all to authenticated
      using (coach_id = auth.uid()) with check (coach_id = auth.uid() and split_part(path, '/', 1) = auth.uid()::text);
  end if;
end $$;
grant select, insert, update, delete on public.coach_videos to authenticated;

-- Cota: 20 vídeos por treinador na biblioteca (conta os arquivos, não as linhas).
create or replace function public.videos_biblioteca_cabe()
returns boolean language sql stable security definer set search_path = public, storage as $$
  select (select count(*) from storage.objects o where o.bucket_id = 'videos' and o.name like auth.uid()::text || '/biblioteca/%') < 20;
$$;
revoke execute on function public.videos_biblioteca_cabe() from public, anon;
grant execute on function public.videos_biblioteca_cabe() to authenticated;

-- Treinador vê o vídeo de sessão do aluno: vínculo ativo, treinos e cargas compartilhados, até 90 dias.
create or replace function public.videos_coach_ve_sessao(p_aluno text, p_criado timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select p_criado > now() - interval '90 days' and exists (select 1 from public.coach_links l
    where l.coach_id = auth.uid() and l.student_id::text = p_aluno and l.status = 'ativo'
      and coalesce((l.permissions->>'ver_treinos')::boolean, true) and coalesce((l.permissions->>'ver_cargas')::boolean, true));
$$;
revoke execute on function public.videos_coach_ve_sessao(text, timestamptz) from public, anon;
grant execute on function public.videos_coach_ve_sessao(text, timestamptz) to authenticated;

-- Aluno vê o vídeo da biblioteca do treinador com quem tem vínculo ativo.
create or replace function public.videos_aluno_ve_biblioteca(p_coach text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coach_links l
    where l.student_id = auth.uid() and l.coach_id::text = p_coach and l.status = 'ativo');
$$;
revoke execute on function public.videos_aluno_ve_biblioteca(text) from public, anon;
grant execute on function public.videos_aluno_ve_biblioteca(text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'videos_insert_own') then
    create policy videos_insert_own on storage.objects for insert to authenticated
      with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text
        and ((storage.foldername(name))[2] = 'sessao'
          or ((storage.foldername(name))[2] = 'biblioteca' and public.videos_biblioteca_cabe())));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'videos_select') then
    create policy videos_select on storage.objects for select to authenticated
      using (bucket_id = 'videos' and (
        (storage.foldername(name))[1] = auth.uid()::text
        or ((storage.foldername(name))[2] = 'sessao' and public.videos_coach_ve_sessao((storage.foldername(name))[1], created_at))
        or ((storage.foldername(name))[2] = 'biblioteca' and public.videos_aluno_ve_biblioteca((storage.foldername(name))[1]))));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'videos_delete_own') then
    create policy videos_delete_own on storage.objects for delete to authenticated
      using (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;
