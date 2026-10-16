-- Convite por e-mail: (a) aviso ao amigo convidado pela lista; (b) convite a quem ainda não tem conta.
-- O envio é feito pela edge function `convidar-email` (Resend); aqui ficam as regras e o limite de abuso.
-- Limite: 15 e-mails por pessoa por dia; o mesmo endereço não recebe o mesmo desafio duas vezes em 7 dias.

alter table public.challenge_invites add column if not exists emailed_at timestamptz;

create table if not exists public.convite_email_log (
  id bigint generated always as identity primary key,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_email text not null,
  challenge_id uuid references public.challenges(id) on delete set null,
  kind text not null check (kind in ('amigo', 'novo')),
  created_at timestamptz not null default now()
);
create index if not exists convite_email_log_from_idx on public.convite_email_log (from_user, created_at desc);
alter table public.convite_email_log enable row level security;
revoke all on public.convite_email_log from public, anon, authenticated;

create or replace function public.convite_email_preparar(p_id uuid, p_user_ids uuid[] default null, p_email text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_ch public.challenges;
  v_from text;
  v_my_email text;
  v_email text;
  v_targets jsonb := '[]'::jsonb;
  r record;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if not public.is_challenge_member(p_id) then raise exception 'você não participa deste desafio'; end if;
  if (select count(*) from public.convite_email_log where from_user = me and created_at > now() - interval '24 hours') >= 15 then
    raise exception 'limite diário de convites por e-mail atingido';
  end if;
  select * into v_ch from public.challenges where id = p_id;
  select coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)), u.email
    into v_from, v_my_email
    from auth.users u left join public.app_data a on a.user_id = u.id where u.id = me;

  if p_email is not null then
    v_email := lower(trim(p_email));
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'e-mail inválido'; end if;
    if v_email = lower(v_my_email) then raise exception 'esse é o seu e-mail'; end if;
    if exists (select 1 from public.challenge_members m join auth.users u on u.id = m.user_id where m.challenge_id = p_id and lower(u.email) = v_email) then
      raise exception 'essa pessoa já está no desafio';
    end if;
    if exists (select 1 from public.convite_email_log where lower(to_email) = v_email and challenge_id = p_id and created_at > now() - interval '7 days') then
      raise exception 'esse e-mail já foi convidado para este desafio';
    end if;
    insert into public.convite_email_log (from_user, to_email, challenge_id, kind) values (me, v_email, p_id, 'novo');
    v_targets := v_targets || jsonb_build_array(jsonb_build_object('email', v_email));
  end if;

  if p_user_ids is not null then
    for r in
      update public.challenge_invites i set emailed_at = now()
       where i.challenge_id = p_id and i.from_user = me and i.status = 'pending' and i.emailed_at is null and i.to_user = any (p_user_ids)
       returning i.to_user
    loop
      select email into v_email from auth.users where id = r.to_user;
      if v_email is not null then
        insert into public.convite_email_log (from_user, to_email, challenge_id, kind) values (me, lower(v_email), p_id, 'amigo');
        v_targets := v_targets || jsonb_build_array(jsonb_build_object('email', v_email));
      end if;
    end loop;
  end if;

  return jsonb_build_object('nome', v_ch.nome, 'code', v_ch.invite_code, 'from_nome', v_from, 'targets', v_targets);
end;
$$;
revoke all on function public.convite_email_preparar(uuid, uuid[], text) from public, anon;
grant execute on function public.convite_email_preparar(uuid, uuid[], text) to authenticated;
