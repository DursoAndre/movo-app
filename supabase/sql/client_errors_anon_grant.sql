-- client_errors só tinha grant de insert pra authenticated — qualquer log de
-- erro disparado ANTES do login (ex: "sessão sumiu, precisei logar de novo")
-- roda com a role anônima (sem sessão == sem token == role anon no Postgres),
-- então esses inserts vinham falhando silenciosamente, sem erro visível pra
-- ninguém perceber. A policy de RLS já cobre isso (user_id is null libera o
-- insert), só faltava o grant de privilégio na tabela em si.
grant insert on public.client_errors to anon;
