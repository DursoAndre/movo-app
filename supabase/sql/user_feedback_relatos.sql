-- Relatos de problema com contexto técnico (v200).
-- O botão "Reportar problema" (menu, barra de erro e tela de erro do app) grava em
-- user_feedback com tipo 'problema', a origem do relato e um jsonb com o contexto:
-- versão, aparelho, aba, últimos erros e telas, e o stack quando a tela quebrou.
-- O agente de revisão (tarefa agendada do projeto) lê os relatos sem revisão e
-- grava o diagnóstico em `revisao`/`revisado_em`.

alter table public.user_feedback add column if not exists origem text not null default 'manual';
alter table public.user_feedback add column if not exists contexto jsonb;
alter table public.user_feedback add column if not exists revisao text;
alter table public.user_feedback add column if not exists revisado_em timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_feedback_origem_chk') then
    alter table public.user_feedback add constraint user_feedback_origem_chk
      check (origem in ('manual', 'erro', 'tela_quebrou'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'user_feedback_contexto_tam_chk') then
    alter table public.user_feedback add constraint user_feedback_contexto_tam_chk
      check (contexto is null or pg_column_size(contexto) <= 32000);
  end if;
end $$;

-- quem envia não escreve a revisão (só o agente/admin, por fora do RLS)
create or replace function public.user_feedback_saneia()
returns trigger language plpgsql as $$
begin
  new.revisao := null;
  new.revisado_em := null;
  return new;
end;
$$;

create or replace trigger user_feedback_saneia_trg before insert on public.user_feedback
  for each row execute function public.user_feedback_saneia();

-- fila do agente: relatos de problema ainda sem revisão
create index if not exists user_feedback_sem_revisao_idx
  on public.user_feedback (created_at) where tipo = 'problema' and revisado_em is null;

-- aba Admin do app (Suporte): contexto e revisão dos relatos
create or replace function public.admin_feedback_contexto(p_ids bigint[])
returns table (id bigint, origem text, contexto jsonb, revisao text, revisado_em timestamptz)
language sql
security definer
set search_path = public, auth
as $$
  select f.id, f.origem, f.contexto, f.revisao, f.revisado_em
  from public.user_feedback f
  where f.id = any(p_ids)
    and public.is_movo_admin();
$$;

grant execute on function public.admin_feedback_contexto(bigint[]) to authenticated;
