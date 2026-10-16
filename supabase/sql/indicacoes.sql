-- "Traga seu amigo pro Movo": cada pessoa tem um código de indicação; o link é
-- https://movoapp.com.br/convite/?amigo=CODIGO. Quem cria conta por esse link fica com user_origem.ref_code = CODIGO.
-- A pessoa vê só números (entraram / já treinaram), nunca nomes. Idempotente.

alter table public.user_origem add column if not exists ref_code text;
create index if not exists user_origem_ref_idx on public.user_origem (ref_code) where ref_code is not null;

create table if not exists public.user_referral (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique,
  criado_em timestamptz not null default now()
);
alter table public.user_referral enable row level security;
revoke all on public.user_referral from public, anon, authenticated;

create or replace function public.my_referral()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_code text;
  v_try int := 0;
begin
  if me is null then raise exception 'not authenticated'; end if;
  select code into v_code from public.user_referral where user_id = me;
  if v_code is null then
    loop
      v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 7));
      begin
        insert into public.user_referral (user_id, code) values (me, v_code);
        exit;
      exception when unique_violation then
        select code into v_code from public.user_referral where user_id = me;
        exit when v_code is not null;
        v_try := v_try + 1;
        if v_try > 10 then raise exception 'não consegui gerar o código'; end if;
      end;
    end loop;
  end if;
  return jsonb_build_object(
    'code', v_code,
    'entraram', (select count(*) from public.user_origem o where o.ref_code = v_code and o.user_id <> me),
    'treinaram', (select count(*) from public.user_origem o where o.ref_code = v_code and o.user_id <> me
                  and exists (select 1 from public.app_events e where e.user_id = o.user_id and e.name = any (public._m_treino())))
  );
end;
$$;
revoke all on function public.my_referral() from public, anon;
grant execute on function public.my_referral() to authenticated;
