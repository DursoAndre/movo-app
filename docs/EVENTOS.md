# Eventos de uso do Movo (`app_events`)

Cada linha: `user_id`, `name`, `created_at` e, desde a v177, `props` (jsonb, opcional). Aberturas do app ficam em `app_opens`
(`versao`, `host`, `instalado`). Origem do cadastro fica em `user_origem` (uma linha por conta, v177+).
Este arquivo é a fonte para reinterpretar números antigos: se mudar o que um evento significa, escreva aqui.

## Definição única de "treinou"
`treino_registrado` (v177+), `treino_concluido`, `primeiro_registro` e `corrida_registrada_manual` (ver `_m_treino()` em
`supabase/sql/admin_metricas_v3.sql`). Conta-se por pessoa e dia, então eventos repetidos no mesmo dia valem um.
Strava não entra: `strava_importado { n }` registra só que houve importação (o evento nasce no dia do sync, não no da atividade).

## `treino_registrado` { tipo, origem }
| tipo | origem | quando dispara |
|---|---|---|
| academia | app | ao concluir um treino de ficha |
| corrida | manual | ao salvar corrida registrada à mão |
| corrida | plano | ao marcar "fiz" numa sessão de corrida do plano |
| atividade | app | ao marcar "fui" numa atividade (exceto descanso) |

## Origem do cadastro (`user_origem`)
Primeiro toque guardado no aparelho (`utm_source`, `pos`, tipo de convite: `desafio`, `treinador`, `prof`) e gravado uma vez
após o login, só para contas criadas há menos de 2 dias. Contas anteriores à v177 aparecem como "sem registro".

## `tela_*`
Uma vez por tela principal a cada abertura do app (`tela_hoje`, `tela_treinos`, `tela_evolucao`, `tela_desafios`).
Mede navegação, não adoção; fica oculto por padrão no painel.

## Cuidados ao ler
- Eventos de treino/onboarding só existem desde 05/10/2026; o funil e a ativação usam só contas criadas desde essa data.
- `*_aberta`/`*_aberto` medem abertura de tela, não uso real da funcionalidade.
- `primeiro_registro` depende de `localStorage` (troca de aparelho ou de endereço pode zerar a marca).
- O painel exclui contas listadas em `app_config.metricas_excluir` (hoje: o admin).
