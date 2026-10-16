-- Nome de quem compartilhou relatório comigo (usado na tela "Compartilhados comigo").
-- Requer base_app_e_amigos.sql e report_shares_setup.sql. Seguro rodar de novo.
create or replace function public.get_share_owner_names()
returns table(owner_user_id uuid, nome text)
language sql
security definer
set search_path to 'public', 'auth'
as $$
  select rs.owner_user_id, coalesce(ad.display_name, rs.owner_email)
  from public.report_shares rs
  left join public.app_data ad on ad.user_id = rs.owner_user_id
  where rs.viewer_email = auth.email() and rs.revoked_at is null;
$$;
revoke all on function public.get_share_owner_names() from public, anon;
grant execute on function public.get_share_owner_names() to authenticated;
