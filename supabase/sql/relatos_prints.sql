-- Prints no "Fale com a gente" (v203, qualquer categoria): até 3 imagens por mensagem, reduzidas no aparelho
-- (lado maior 1280px, JPEG). Bucket PRIVADO "relatos", pasta = user_id. Só o dono grava/lê/apaga
-- a própria pasta; o admin (is_movo_admin) lê tudo e vê pelo painel de métricas com URL assinada.
-- Seguro rodar de novo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('relatos', 'relatos', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

drop policy if exists relatos_insert_own on storage.objects;
create policy relatos_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'relatos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists relatos_select_own_ou_admin on storage.objects;
create policy relatos_select_own_ou_admin on storage.objects for select to authenticated
  using (bucket_id = 'relatos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_movo_admin()));
drop policy if exists relatos_delete_own on storage.objects;
create policy relatos_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'relatos' and (storage.foldername(name))[1] = auth.uid()::text);

alter table public.user_feedback add column if not exists prints text[];
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_feedback_prints_chk') then
    alter table public.user_feedback add constraint user_feedback_prints_chk
      check (prints is null or cardinality(prints) <= 3);
  end if;
end $$;
