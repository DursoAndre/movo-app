# Banco do Movo (Supabase)

Tudo que existe no banco está em `sql/` — um arquivo por assunto. Em **produção nada precisa ser rodado de novo**: os arquivos documentam o que já está aplicado (os de base foram extraídos do banco em 16/10/2026).

## Montar um projeto novo
1. `python3 supabase/build_setup.py` gera `supabase/setup_completo.sql` (todos os arquivos, na ordem de `ordem.txt`).
2. Cole no SQL Editor do Supabase novo e rode.
3. A parte de alertas por e-mail (`monitoramento.sql`, no final) usa as extensões `pg_cron`, `pg_net` e o Vault — ative-as no painel antes (Database → Extensions) e crie os segredos que o arquivo cita.
4. Depois: Edge Functions (`supabase/functions/`), bucket `avatars` (já criado por `avatars_setup.sql`), URLs de Auth e segredos (Strava, IA).

`build_setup.py` falha se algum arquivo de `sql/` não estiver em `ordem.txt` — ao criar um `.sql` novo, adicione-o lá na posição certa (depois de tudo de que ele depende).

## Mapa
| Grupo | Arquivos |
|---|---|
| Base | `base_app_e_amigos` (app_data, amizades, ranking de amigos) |
| Conta e privacidade | `user_consents`, `account_data_rights` (exportar/excluir conta; **sempre depois de `coach_contato`**) |
| Diagnóstico | `client_errors_*`, `user_feedback_setup`, `app_opens_setup`, `app_events_setup`, `monitoramento` |
| Dados do treino | `save_sessions_days`, `avatars_setup`, `strava_*`, `report_shares_*`, `races_cloud_setup` |
| Desafios | `challenges_setup`, `challenge_timeline` |
| IA | `plan_generations_setup`, `plan_limit_admin`, `ai_quota_kinds`, `ai_usage_cost`, `ai_kill_switch` (cria `app_config`), `ai_jobs_setup` |
| Config e experimentos | `app_config_dominio`, `feature_flags*` |
| Catálogo | `exercise_gaps_*`, `catalogo_banco` (define `is_movo_admin()`) |
| Planos/cobrança (dormente) | `billing_base`, `billing_trial_limites` |
| Treinadores | `coach_setup`, `coach_setup_v2`, `coach_admin`, `coach_agenda_*`, `coach_contato` |
| Painel admin | `admin_*` |
| Landing | `lp_events` |

## Regras
- Arquivos novos devem ser idempotentes (`if not exists`, `create or replace`, `drop policy if exists`). Alguns dos mais antigos (`strava_setup`, `client_errors_setup`, `user_feedback_setup`) só funcionam em banco vazio.
- Mudou algo direto no painel/MCP? Atualize o arquivo correspondente aqui, para o banco poder ser recriado.
