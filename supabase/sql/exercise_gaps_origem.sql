-- De onde veio cada exercício fora do catálogo (v161): 'picker' (digitado na busca), 'import_ficha' (importar ficha do
-- treinador), 'import_historico', 'ia'. Alimenta a revisão do catálogo. Seguro rodar de novo.
alter table public.exercise_suggestions add column if not exists origem text not null default 'picker';
alter table public.exercise_suggestions drop constraint if exists exercise_suggestions_origem_check;
alter table public.exercise_suggestions add constraint exercise_suggestions_origem_check check (origem in ('picker', 'import_ficha', 'import_historico', 'ia'));
