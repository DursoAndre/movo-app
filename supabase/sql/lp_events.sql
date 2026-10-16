-- Contadores anônimos de visita da landing page (movoapp.com.br): só dia + evento + posição + origem, sem cookie, sem IP.
-- A página chama a função lp_event com a chave pública; a tabela não tem política (ninguém lê de fora; só o painel/SQL).
-- Para ver: select day, name, pos, src, n from public.lp_events order by day desc, n desc;
-- Seguro rodar de novo.
create table if not exists public.lp_events (
  day date not null default current_date,
  name text not null,
  pos text not null default '',
  src text not null default '',
  n bigint not null default 0,
  primary key (day, name, pos, src)
);
alter table public.lp_events enable row level security;

create or replace function public.lp_event(p_name text, p_pos text default '', p_src text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_name not in ('view','cta_open_app','video_play','chapter','click_email','install_guide') then return; end if;
  if p_pos not in ('','nav','hero','video','vantagens','desafio','treinador','faq','final','sticky','install','ficha','treinar','desafios','corrida','treinadores','como-funciona','videos','recursos','instalar','perguntas') then p_pos := ''; end if;
  if p_src not in ('','whatsapp','instagram','indicacao','direto','facebook','tiktok','google','youtube','linkedin','email','lp') then p_src := 'outro'; end if;
  insert into public.lp_events(day,name,pos,src,n) values (current_date,p_name,p_pos,p_src,1)
  on conflict (day,name,pos,src) do update set n = public.lp_events.n + 1;
end $$;
revoke all on function public.lp_event(text,text,text) from public;
grant execute on function public.lp_event(text,text,text) to anon, authenticated;
