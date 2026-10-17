-- Avisos por e-mail (edge function `avisar-email`): (a) pedido do aluno a um treinador; (b) relatório liberado para alguém.
-- Só avisa quem já tem conta no Movo (nunca manda e-mail a endereço solto). Limite: 15 por pessoa por dia; o mesmo aviso não repete em 7 dias.
create table if not exists public.aviso_email_log (
  id bigint generated always as identity primary key,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid references auth.users(id) on delete set null,
  tipo text not null check (tipo in ('pedido_treinador', 'relatorio')),
  ref text not null,
  created_at timestamptz not null default now()
);
create index if not exists aviso_email_log_from_idx on public.aviso_email_log (from_user, created_at desc);
alter table public.aviso_email_log enable row level security;
revoke all on public.aviso_email_log from public, anon, authenticated;

create or replace function public.aviso_email_preparar(p_tipo text, p_ref text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_from text; v_to uuid; v_email text; v_inv public.coach_student_invites; v_sh public.report_shares;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if p_tipo not in ('pedido_treinador', 'relatorio') then raise exception 'tipo inválido'; end if;
  if (select count(*) from public.aviso_email_log where from_user = me and created_at > now() - interval '24 hours') >= 15 then
    raise exception 'limite diário de avisos por e-mail atingido';
  end if;
  if exists (select 1 from public.aviso_email_log where from_user = me and tipo = p_tipo and ref = p_ref and created_at > now() - interval '7 days') then
    raise exception 'aviso já enviado';
  end if;
  select coalesce(nullif(trim(a.display_name), ''), split_part(u.email, '@', 1)) into v_from
    from auth.users u left join public.app_data a on a.user_id = u.id where u.id = me;

  if p_tipo = 'pedido_treinador' then
    select * into v_inv from public.coach_student_invites
     where invite_code = upper(trim(p_ref)) and student_id = me and para_coach is not null and status = 'aberto';
    if not found then raise exception 'pedido não encontrado'; end if;
    v_to := v_inv.para_coach;
  else
    select * into v_sh from public.report_shares where id = nullif(p_ref, '')::bigint and owner_user_id = me and revoked_at is null;
    if not found then raise exception 'compartilhamento não encontrado'; end if;
    select id into v_to from auth.users where lower(email) = lower(v_sh.viewer_email) limit 1;
    if v_to is null then raise exception 'essa pessoa ainda não tem conta no Movo'; end if;
  end if;
  select email into v_email from auth.users where id = v_to;
  if v_email is null then raise exception 'destinatário sem e-mail'; end if;
  insert into public.aviso_email_log (from_user, to_user, tipo, ref) values (me, v_to, p_tipo, p_ref);
  return jsonb_build_object('tipo', p_tipo, 'from_nome', v_from, 'to_email', v_email);
end;
$$;
revoke all on function public.aviso_email_preparar(text, text) from public, anon;
grant execute on function public.aviso_email_preparar(text, text) to authenticated;
