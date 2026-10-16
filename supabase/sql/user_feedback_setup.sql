create table public.user_feedback (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  tipo text not null default 'ideia',
  mensagem text not null,
  contato boolean not null default true,
  versao text,
  lido boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.user_feedback enable row level security;

grant select, insert on public.user_feedback to authenticated;

create policy user_feedback_insert_own on public.user_feedback
  for insert with check (auth.uid() = user_id and char_length(mensagem) between 3 and 2000);

create policy user_feedback_select_own on public.user_feedback
  for select using (auth.uid() = user_id);

create or replace function public.admin_feedback_list(limit_n int default 100)
returns table (id bigint, created_at timestamptz, email text, tipo text, mensagem text, contato boolean, versao text, lido boolean)
language sql
security definer
set search_path = public, auth
as $$
  select f.id, f.created_at, u.email, f.tipo, f.mensagem, f.contato, f.versao, f.lido
  from public.user_feedback f
  left join auth.users u on u.id = f.user_id
  where (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com'
  order by f.lido asc, f.created_at desc
  limit limit_n;
$$;

grant execute on function public.admin_feedback_list(int) to authenticated;

create or replace function public.admin_feedback_lido(p_id bigint, p_lido boolean)
returns void
language sql
security definer
set search_path = public, auth
as $$
  update public.user_feedback set lido = p_lido
  where id = p_id
    and (select email from auth.users where id = auth.uid()) = 'ardurso@gmail.com';
$$;

grant execute on function public.admin_feedback_lido(bigint, boolean) to authenticated;

-- limite: 10 por dia por pessoa
create or replace function public.user_feedback_limite()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.user_feedback
      where user_id = new.user_id and created_at > now() - interval '1 day') >= 10 then
    raise exception 'limite_feedback';
  end if;
  return new;
end;
$$;

create trigger user_feedback_limite_trg before insert on public.user_feedback
  for each row execute function public.user_feedback_limite();
