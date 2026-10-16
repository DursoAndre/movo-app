# Plano: do Movo de amigos ao Movo público (e pago)

Objetivo: abrir para usuários externos e, depois, cobrar. Escrito em 10/10/2026, a revisar a cada fase.
Tamanhos: **P** = uma sessão de trabalho, **M** = 2 a 4 sessões, **G** = mais de 4 ou depende de terceiros.
"Andre" = coisas que só você pode fazer (contas, jurídico, decisões). Conferir preços e regras das lojas e da lei na hora de executar: mudam.

## Princípio
Antes de trazer estranhos, o app precisa **não perder dado, não gastar dinheiro sem controle e ser claro sobre privacidade**. Só depois vêm lojas e cobrança. Cada fase termina com algo que dá pra entregar e medir.

## Fase 0: Decisões (antes de tudo)
| Decisão | Por quê |
|---|---|
| Nome e marca "Movo": checar INPI, domínio (.com.br/.app), perfis sociais | Trocar de nome depois custa caro (lojas, link, usuários) |
| Pessoa física ou CNPJ/MEI | Cobrança, conta de loja e nota fiscal dependem disso |
| Modelo: grátis com limite de IA + plano pago (sugestão) | Define cotas e o que o paywall bloqueia |
| Quem é o público inicial: corredor-que-treina-academia (já é o foco do app) | Guia onboarding, texto da loja e canais |

## Fase 1: Fundação (confiança e segurança)
1. **Sincronização confiável (M). FEITO na v102** (fila com nova tentativa, mescla por dia, indicador e "Sincronizar agora"; falta só resolver conflito de edição simultânea das fichas em dois aparelhos, hoje vence a última gravação). Hoje tudo vai em uma linha `app_data` por pessoa, e já vemos `persist_upsert: Load failed` nos erros. Fazer: fila local que tenta de novo ao reconectar e ao voltar pro app; indicador "sincronizado / pendente"; mesclar por dia em vez de sobrescrever tudo (evita perder treino se o mesmo usuário abrir em dois aparelhos); coluna de versão/`updated_at` pra detectar conflito. Depois, se preciso, quebrar `app_data` em tabelas.
2. **Excluir conta e exportar dados (M) — FEITO v103 (falta rodar `supabase/sql/account_data_rights.sql`).** Botão em Configurações que apaga tudo (inclusive Strava e feedbacks) e baixa um arquivo com os dados. Exigido pela LGPD e pelas lojas.
3. **Privacidade e termos (M, com Andre).** Política de privacidade e termos de uso em página própria; consentimento explícito no primeiro login (dado de saúde é dado pessoal sensível na LGPD); citar os operadores (Supabase, Anthropic para a IA, Strava, Resend); canal de contato do titular; aviso de que não substitui profissional de saúde. **Andre:** revisão de um advogado.
4. **Segurança (P).** Revisão do Supabase já feita (v101); falta: limites de taxa nas funções de IA, teto global diário de gasto com **chave de desligar** (kill switch), rotação de segredos, política de backup do banco.
5. **Hospedagem e build (M, ver item 5 do ROADMAP). Build FEITO v109 (esbuild + GitHub Actions, sem Babel/CDN no navegador); falta domínio próprio.** Domínio próprio, build minificado (esbuild) em vez de Babel no navegador, sourcemaps privados, deploy por CI. Mudar a URL no login do Supabase e no Strava. Faz sentido já com o domínio definitivo.
6. **Testes no repositório (M).** Hoje os testes de tela ficam fora do repo (pasta de trabalho). Mover para `tests/`, rodar no GitHub Actions a cada push. Sem isso, cada mudança é arriscada com usuários reais.
7. **Monitoramento (P).** Painel de erros já existe; adicionar alerta por e-mail quando sobe muito e registro de falha das edge functions.

**Pronto quando:** dois aparelhos não se sobrescrevem, uma conta pode ser apagada, política publicada, build automatizado com testes, teto de gasto ativo.

## Fase 2: Beta aberto (50 a 200 pessoas)
1. **Onboarding (M).** Medir onde as pessoas desistem nos primeiros 2 minutos; fluxo de 3 telas (objetivo, dias, primeira ficha ou plano com IA); estado vazio com próxima ação clara.
2. **Entrada controlada (P).** Link de convite ou lista de espera, pra liberar aos poucos e controlar custo de IA.
3. **Métricas de produto (P).** Retenção D1/D7/D30, ativação (primeiro treino registrado), uso de IA, funil de onboarding no painel admin (os eventos já existem em `app_events`).
4. **E-mail transacional (P).** Resend com domínio verificado (hoje só entrega pro seu e-mail): boas-vindas, recuperação, avisos.
5. **Suporte e feedback (P).** O botão de feedback já existe; criar rotina semanal de ler, responder e priorizar.
6. **Custo da IA (P).** Painel de custo por usuário (já existe `admin_ai_cost`) + alerta; definir o que é grátis.

**Pronto quando:** 50+ pessoas externas ativas, retenção D7 medida e sem incidente de dado.

## Fase 3: Engajamento
1. **Notificações push (G).** Chaves VAPID, tabela de assinaturas, edge function agendada. Lembrete de treino, "sua semana mudou", desafio de amigo, resumo semanal. No iPhone só funciona com o app instalado na tela inicial. Pedir permissão no momento certo, nunca no primeiro acesso.
2. **Ciclo semanal (M).** Resumo da semana (o que fez, o que ajustou) e convite para "Ajustar minha semana" no domingo.
3. **Compartilhamento (P).** Cartão de treino/semana para stories (já temos cartões de desafio).
4. Evolução mostrar ajustes e usar o histórico de cargas na progressão (itens já listados).

## Fase 4: Lojas
1. **Android (M).** Empacotar o PWA (TWA ou Capacitor), ícones, capturas de tela, ficha da loja, política de privacidade e formulário de segurança de dados, link de exclusão de conta. **Andre:** conta de desenvolvedor Google (taxa única, hoje cerca de US$ 25); contas pessoais novas costumam exigir teste fechado com testadores por algumas semanas antes de publicar.
2. **iOS (G).** Capacitor, conta Apple (US$ 99/ano), recursos nativos que justifiquem não ser "só um site" (push, Apple Health talvez), revisão da Apple. Deixar pra depois do Android, ou só PWA no iPhone no começo.
3. **Atualização do app (P).** Estratégia de versões: hoje o service worker atualiza sozinho; no app empacotado, mostrar "nova versão disponível".
4. **Integração de saúde (G, opcional).** Google Health Connect (Android) em vez de depender só do Strava.

## Fase 5: Cobrança
1. **Planos (M).** Sugestão: grátis (fichas, agenda, Evolução, desafios, poucas gerações de IA) e Pro (mais IA, ajustes semanais ilimitados, importar histórico, exportar). Cotas já existem por tipo (`plano_corrida`, `historico`, `treino`, `ajuste_semana`): bastam limites por plano.
2. **Pagamento (G).** Na web: Stripe (cartão e Pix) ou Mercado Pago/Asaas, com assinatura recorrente. **Dentro das lojas, assinatura digital normalmente precisa usar a cobrança da própria loja (Google Play Billing / Apple IAP)**, com comissão. Decidir se vende só pela web no começo.
3. **Banco (P).** Tabela `assinaturas`, webhook do pagamento numa edge function, status refletido nas funções de cota.
4. **Fiscal e legal (G, Andre).** CNPJ/MEI, nota fiscal, termos de cobrança e reembolso, direito de arrependimento (CDC).
5. **Paywall (P).** Mostrar o valor no momento em que a pessoa bate no limite, não antes.

## Em paralelo: qualidade do código
- **Modularizar `app.js` (G, incremental).** ~12 mil linhas num arquivo. Fazer junto com o build: separar por área (treino, corrida, desafios, admin, IA) e tirar componentes grandes. Sempre com os testes rodando no CI.
- **Acessibilidade e idioma (P).** Contraste, foco, textos em PT-BR consistentes; decidir se haverá inglês.
- **Desempenho (P).** Tempo de abertura em celular fraco; carregar admin e modais de IA sob demanda.

## Linha do tempo estimada (trabalhando em sessões curtas)
| Etapa | Tempo |
|---|---|
| Fase 0 | 1 semana (principalmente decisão e checagem de marca) |
| Fase 1 | 3 a 5 semanas |
| Fase 2 | 4 a 6 semanas de beta |
| Fase 3 | 3 a 4 semanas (pode começar junto da Fase 2) |
| Fase 4 (Android) | 3 a 5 semanas, incluindo o teste fechado |
| Fase 5 | 4 a 6 semanas, dependendo da parte fiscal |

## Riscos principais
1. **Perda de dado por sincronização:** o pior que pode acontecer com confiança de usuário. Por isso é o item 1.
2. **Custo de IA sem teto:** cota por usuário + teto global + kill switch antes de abrir.
3. **Conformidade (LGPD, lojas):** não deixar para o fim; exclusão de conta e política precisam estar prontas antes do beta.
4. **Dependência do Strava e das APIs de IA:** limites e mudanças de regra; plano B para entrada de dados manual.
5. **Rejeição da Apple:** app que é só um site embrulhado costuma ser recusado.
6. **Suporte:** cada usuário externo gera mensagens; a rotina de feedback precisa existir antes de escalar.

## Próximos passos imediatos
1. Fase 0: decidir nome/marca, CNPJ/MEI, modelo de plano.
2. Fase 1 item 1 (sincronização) e item 2 (excluir conta e exportar): são pré-requisito de tudo.
3. Mover os testes para o repositório e ligar o CI.

## Experimento: Ajustar minha semana (v155)
O ajuste da semana com IA ainda não provou utilidade, e a política da API do Strava proíbe usar dados do Strava em IA. Por isso o recurso (menu "Ajustar minha semana" e o card "Sua semana mudou") fica atrás de uma lista de liberados (`supabase/sql/feature_flags.sql`): o admin libera por e-mail em Configurações > Admin, e quem conectou o Strava fica de fora, com a trava também no servidor (`reserve_ai_generation`). Por enquanto está liberado pra todos sem Strava (`feature_flags_todos.sql`; o admin desliga o "pra todos" no mesmo painel). Medir: uso, aceitação do ajuste e retorno no dia seguinte. Plano de corrida com IA (v156): corridas importadas do Strava (comentário "Importado do Strava") ficam fora do histórico, do pace e do replanejamento que vão no prompt; o formulário só mostra o que o Strava tem, sem preencher nem enviar. Se o Strava mudaria as contagens do replanejamento, o prompt não leva as contagens e pede retomada conservadora.

## Planos e cobrança, base dormente (v158)

Objetivo: deixar o Movo pronto pra cobrar sem mudar nada pra ninguém hoje. Plano de lançamento: PWA na web, sem Play Store, cobrança via Asaas (CNPJ) quando for a hora (ver business plan).

- **SQL:** `supabase/sql/billing_base.sql`. Tabela `assinaturas` (sem policies; grátis = sem linha; linhas `aluno` e `treinador`), `my_plan()`, `plano_efetivo`, `plano_limites` (único lugar com limites por plano), duas chaves em `app_config`: `billing_visivel` e `billing_limites` (ambas `false`).
- **Com `billing_limites` ligada:** `reserve_ai_generation` / `ai_generation_usage` usam a cota do plano (grátis 2 por recurso, Pro 30) em vez do número que o app manda; `coach_create_invite` bloqueia acima do nº de alunos do plano (erro `limite_plano_alunos`). Admin sempre sem limite.
- **App:** `PLANOS_CATALOGO` (vitrine; preços iguais aos do SQL/business plan), `MeuPlanoModal`, grupo "Plano" em Configurações e "Ver planos" nos avisos de limite, tudo só quando `my_plan().visivel`. O botão "Tenho interesse" só grava o evento `plano_interesse_<linha>_<plano>` (mede demanda, não cobra).
- **Admin (Uso do Movo > PLANOS E COBRANÇA):** liga/desliga as duas chaves, dá plano por e-mail (cortesia ou teste de 14 dias) e remove.
- **Falta pro checkout:** conta Asaas + CNPJ, função de borda de webhook que grava em `assinaturas` (`origem = 'asaas'`), tela de pagamento, cancelamento, direito de arrependimento de 7 dias, termos revisados. Strava segue grátis (política da API do Strava).

### Atualização v159: teste de 30 dias e grátis limitado do avulso (dormente)

Decisão do business plan (revisão de 13/10): teste de 30 dias com tudo liberado, depois plano Grátis útil; Pro R$ 19,90/mês ou R$ 129/ano. `supabase/sql/billing_trial_limites.sql` (rodar depois de `billing_base.sql`).

- **Aluno:** admin e assinatura Pro = `pro`; vinculado a treinador com plano pago = `pro` (cobertura `treinador`); dentro do teste = `teste`; senão `gratis`. O teste conta 30 dias do maior entre cadastro, dia em que o admin ligou os limites (`billing_limites_desde`) e fim do último vínculo com treinador.
- **Grátis:** registro ilimitado, 2 fichas (só trava criar mais; as existentes seguem), evolução de 3 meses (12 meses e "desde sempre" com cadeado), 1 uso de IA por mês em cada recurso, participar de desafios (criar é Pro, travado no servidor em `create_challenge`). Nenhum dado é apagado.
- **App:** `planoLim()` lê `my_plan().aluno.recursos`; aviso na Hoje nos últimos 10 dias do teste; modal "Meu plano" mostra o teste e a cobertura via treinador.
- **Fora do escopo por ora:** PDF do aluno (hoje só o treinador tem PDF), Pro+ (criar só se houver gente batendo no teto), checkout (Asaas).

## v160: admin em abas
O painel de admin (Configurações > Ver uso) agora tem 6 abas: Geral (KPIs, gráfico, funil, saúde), Usuários (lista e logins), Treinadores (KPIs de treinadores, fila de análise, plano e alunos/limite de cada um), Planos (cobrança), IA (controle, gasto, experimento, planos de corrida) e Suporte (feedback, erros, exercícios fora do catálogo, provas). A aba escolhida fica salva no aparelho. Badges nas abas mostram treinadores em análise e feedback novo. Sem mudança de banco: os números de treinadores vêm de admin_coach_list e admin_plan_list.

## v161: importar ficha com IA (treinador)
No compositor do aluno, "Adicionar em um dia > Importar ficha" lê foto, PDF, planilha, zip/texto do WhatsApp ou texto colado. Função `importar-ficha` (Supabase, mesma infraestrutura do histórico: reserva em `plan_generations` tipo `ficha`, tarefa em `ai_jobs`, custo em `ai_usage_log`). O treinador revisa (nome, dia de cada ficha, remover exercícios, etiqueta "catálogo"/"novo", linha original) e nada vai ao aluno até enviar. "Ler texto (sem IA)" usa o leitor local e não gasta cota. Cota técnica de 30 leituras por mês (sem diferença por plano no beta; com a cobrança ligada vale o limite de IA do plano). Exercícios que não casam com o catálogo entram em `exercise_suggestions` com `origem = 'import_ficha'` (coluna criada por `supabase/sql/exercise_gaps_origem.sql`). Só lê a primeira semana quando a ficha é periodizada (ver backlog no ROADMAP).


## v162: catálogo de exercícios no banco + revisão diária
- **Banco** (`supabase/sql/catalogo_banco.sql`): `catalogo_grupos`, `catalogo_exercicios` (75 do app, mesmos ids = slug do nome), `catalogo_sinonimos`, `catalogo_aliases` (nome que a pessoa digitou → exercício do catálogo) e `exercise_review` (fila de revisão). Leitura pública (anon + logado); escrita só por RPC de admin. `catalogo_versao()` e `catalogo_completo()` entregam tudo numa chamada.
- **App:** o catálogo embutido continua como reserva (offline/primeira abertura). Ao abrir (e ao voltar pro app, no máximo a cada 30 min) o app compara a versão; se mudou, baixa o catálogo, troca o conteúdo dos mesmos arrays (`EXERCISE_CATALOG_FLAT`, `CATALOG_GRUPOS`, `EXERCICIO_SINONIMOS`) e guarda cópia em `localStorage` (`movo_catalogo_v1`). Aliases entram na busca e no compositor do treinador.
- **Revisão diária:** pg_cron `revisar-catalogo-diario` às 02:00 UTC (23:00 de Brasília) chama a função de borda `revisar-catalogo` (segredo em `catalogo_cron_secret`, `verify_jwt` desligado, a checagem é interna). Ela pega nomes de `exercise_suggestions` que ainda não estão no catálogo nem em alias, nem pendentes, e pede à IA uma proposta: **alias** (mesmo exercício), **novo** (nome padrão, grupo, séries, reps, descrição) ou **ignorar**. Respeita `ai_bloqueio()` (IA desligada/teto diário), no máximo 30 nomes por rodada, custo em `ai_usage_log` no nome do admin. A IA só propõe; nada entra no catálogo sem o admin aprovar.
- **Admin > Catálogo:** fila com a proposta da IA (editável), Aprovar / Reprovar com comentário, "Rodar agora", e lista dos decididos com "Reavaliar".
- **Se reprovar:** fica registrado com o comentário e o nome não volta sozinho. Só reaparece se for digitado o dobro de vezes (mínimo 2) desde a decisão, ou se você tocar em Reavaliar. Os últimos 20 comentários de reprovação vão no prompt da próxima revisão (a IA aprende o que você não quer).
- **Backfill:** ao aprovar, o nome original vira alias. Em cada aparelho, o app troca nas fichas da pessoa o exercício livre pelo do catálogo (id, nome, descrição e vídeo se estiverem vazios), mantém séries/reps/observações e move o histórico de cargas pro id novo. Se a ficha já tem o exercício do catálogo, não mexe. Vale pra todo mundo que tinha esse nome. Fica de fora: exercícios adicionados só num dia (`ajustes.added`).

## v163: aviso de mudança de endereço (github.io -> movoapp.com.br)
- Só aparece no endereço antigo (`*.github.io`) e só quando `app_config.dominio_novo.ativo = true`. Chave lida pela RPC pública `app_dominio_novo()`.
- Banner "O Movo tem endereço novo" com botão **Abrir**: grava pendências, envia à nuvem (até 4 s) e abre o domínio novo. Com `redirecionar = true`, leva sozinho assim que a nuvem sincroniza.
- Por quê: ao ligar o domínio no GitHub Pages, o endereço antigo passa a redirecionar e o app instalado não consegue mais buscar o `sw.js` novo. Quem já recebeu a v163 antes disso é redirecionado pelo código guardado no aparelho.
- Ligar (depois do domínio no ar): `update app_config set valor = '{"ativo": true, "redirecionar": false, "url": "https://movoapp.com.br"}' where chave = 'dominio_novo';` Depois de alguns dias, `redirecionar: true`.
