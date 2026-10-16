-- Prêmios P1 (parte 2): sair/excluir desafio respeitando o livro-caixa. Rodar depois de challenge_acertos.sql.
-- Sair do desafio: fecha o que já passou antes (quem sai paga o que deve).
create or replace function public.leave_challenge(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.challenges where id = p_id;
  if v_owner is null then return; end if;
  if v_owner = auth.uid() then raise exception 'quem criou não pode sair: exclua o desafio'; end if;
  perform public._challenge_close(p_id);
  delete from public.challenge_checkins where challenge_id = p_id and user_id = auth.uid();
  delete from public.challenge_together where challenge_id = p_id and (from_user = auth.uid() or to_user = auth.uid());
  delete from public.challenge_members where challenge_id = p_id and user_id = auth.uid();
end;
$$;

-- Excluir: não pode se houver acerto em aberto.
create or replace function public.delete_challenge(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._challenge_close(p_id);
  if exists (
    select 1 from public.challenge_ledger l
    left join public.challenge_acerto_status s on s.ledger_id = l.id
    where l.challenge_id = p_id and s.received_at is null and s.forgiven_at is null
  ) then raise exception 'ainda há acertos em aberto: quite ou perdoe antes de excluir'; end if;
  delete from public.challenges where id = p_id and owner_id = auth.uid();
end;
$$;

