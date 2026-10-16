-- Aviso de mudança de endereço do app (banner "Estamos mudando para ..."). Lido pelo app via app_dominio_novo().
-- Para ligar: update public.app_config set valor = jsonb_set(valor, '{ativo}', 'true') where chave = 'dominio_novo';
-- Requer ai_kill_switch.sql (cria public.app_config). Seguro rodar de novo; não sobrescreve o valor existente.
insert into public.app_config (chave, valor)
values ('dominio_novo', '{"url": "https://app.movoapp.com.br", "ativo": false, "redirecionar": false}'::jsonb)
on conflict (chave) do nothing;

create or replace function public.app_dominio_novo()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select valor from public.app_config where chave = 'dominio_novo'), '{"ativo": false}'::jsonb)
$$;
grant execute on function public.app_dominio_novo() to anon, authenticated;
