-- Revisão dos erros automáticos (client_errors), pedido do Andre em 19/10/2026.
-- O Claude marca no banco o que já revisou (revisado_em + revisao); o painel de métricas
-- (aba Mensagens) mostra por padrão só os erros ainda não revisados, com filtro "Todos".
-- Erro novo de um contexto já revisado volta a aparecer (a marcação é por linha, não por contexto).
alter table public.client_errors add column if not exists revisado_em timestamptz;
alter table public.client_errors add column if not exists revisao text;
create index if not exists client_errors_nao_revisados_idx on public.client_errors (created_at) where revisado_em is null;

-- Para marcar (rodar pelo conector, como admin do banco):
--   update public.client_errors set revisado_em = now(), revisao = '<diagnóstico curto>'
--   where context = '<contexto>' and revisado_em is null;
