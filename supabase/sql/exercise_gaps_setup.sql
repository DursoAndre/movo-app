-- Exercícios que as pessoas criaram na hora ("Não achou? Adicionar ...") por não
-- existirem no catálogo. Serve pra revisar de vez em quando no painel de admin e
-- decidir o que entra no catálogo. Só guarda usuário + nome digitado + hora.
-- Seguro rodar de novo.

create table if not exists public.exercise_suggestions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 80),
  created_at timestamptz not null default now()
);

alter table public.exercise_suggestions enable row level security;

grant insert on public.exercise_suggestions to authenticated;

drop policy if exists exercise_suggestions_insert_own on public.exercise_suggestions;
create policy exercise_suggestions_insert_own on public.exercise_suggestions
  for insert to authenticated with check (auth.uid() = user_id);

-- Ranking dos nomes mais pedidos (agrupa ignorando maiúsculas e acentos). Só o admin recebe linhas.
drop function if exists public.admin_exercise_gaps(int);

create function public.admin_exercise_gaps(dias int default 90)
returns table (nome text, vezes bigint, usuarios bigint, ultima timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select min(trim(s.nome)) as nome,
         count(*) as vezes,
         count(distinct s.user_id) as usuarios,
         max(s.created_at) as ultima
  from public.exercise_suggestions s
  where s.created_at >= now() - make_interval(days => dias)
    and (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  group by lower(translate(trim(s.nome), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC'))
  order by count(*) desc, max(s.created_at) desc
  limit 50;
$$;

grant execute on function public.admin_exercise_gaps(int) to authenticated;
