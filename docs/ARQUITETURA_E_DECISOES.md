# Movo: arquitetura, decisões e estado (fonte de verdade)

Arquivo vivo. **Leia antes de mexer em qualquer coisa. Atualize ao final de cada entrega** (nova decisão, novo arquivo SQL, nova função, nova pendência). Quem escreve aqui é o Claude; quem decide é o Andre.

Última atualização: 16/10/2026 (v190).

---

## 1. O que é o Movo

PWA de treino em português do Brasil. Tudo num lugar só: musculação (fichas, cargas), atividades fora da academia, corrida (treinos estruturados, plano para prova, Strava), provas, desafios entre amigos e modo treinador. Foco em quem corre e tem ficha de musculação e em quem faz muitas atividades.

- Tom de texto: simples, sem intimidar; "musculação" (não "academia"); "histórico de treinos, exercícios e cargas" (não "evolução"); detalhes de interface não entram no pitch.
- Cobrança: ainda não. O app é preparado para "virar a chave" depois (30 dias completos, depois grátis limitado ou Pro mensal/anual). Segue PWA, sem app de loja por enquanto.
- Dono/decisor: Andre (ardurso@gmail.com). Testa no Android.

## 2. Infraestrutura

| Item | Valor |
|---|---|
| Repositório do app | github.com/DursoAndre/movo-app (branch `main`) |
| App em produção | https://app.movoapp.com.br (GitHub Pages via Actions) |
| Site/landing | repositório `movo-site` → https://movoapp.com.br (`_src/build.py` gera; `/convite/` redireciona convites; `/admin/`) |
| Repositório antigo | `meu-treino`: **congelado**, não mexer |
| Domínio | movoapp.com.br (Registro.br) |
| Backend | Supabase, projeto `wgdhjkebfvcmgokxscvb` (Postgres + Auth + Edge Functions) |
| E-mail transacional | Resend (conta criada; domínio movoapp.com.br; ver 2.2) |
| Build | `npm run build` (esbuild, `build.mjs`) no GitHub Actions; publica `dist/` |

### 2.0 Vocabulário: dois "admins" diferentes (não confundir)
| Como o Andre chama | O que é | Onde fica | Dados |
|---|---|---|---|
| **Painel de métricas** (ou "Movo Admin") | PWA separado só de métricas e gestão: visão geral, retenção, funil, ativação, canais, convites, domínio | `movoapp.com.br/admin/`, repositório **movo-site** (pasta `admin/`) | RPCs `admin_m_*` (`admin_metricas*.sql`), só para quem passa em `is_movo_admin()` |
| **Aba Admin do app** | Tela dentro do app normal (menu), com abas Geral, Usuários, IA, Planos, Treinadores, Suporte, Catálogo | `app.js` (repositório **movo-app**), `adminTab` | RPCs `admin_*` (usage_stats, coach_list, feedback...) |

Regra: se o Andre disser só "admin", **perguntar qual** antes de mexer. A lista de contas (ordem de cadastro/último acesso) está na **aba Admin do app › Usuários** (v190). Também está no **painel de métricas** (aba Contas, v. 16/10), com a mesma ordenação e busca.

### 2.1 Regras de entrega (sempre)
- Todo commit que muda o app: subir `APP_BUILD` no `app.js` (ex.: "v189") **e** `CACHE` no `sw.js` (ex.: "treino-app-v189"). Sem isso o cache do service worker segura a versão antiga.
- Commit termina com:
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` e `Claude-Session: https://claude.ai/code/session_015cVe1JQ2CUkwbA3tfmAsiv`.
- Conferir o build no Actions depois do push (`gh api repos/DursoAndre/movo-app/actions/runs`).
- Novo arquivo SQL: criar em `supabase/sql/`, **acrescentar em `supabase/ordem.txt`**, rodar `python3 supabase/build_setup.py` (regenera `setup_completo.sql`).
- Não publicar no site o que não precisa estar lá (ROADMAP, docs). `build.mjs` copia só uma lista de arquivos.

### 2.2 E-mail (Resend)
- Funções que mandam e-mail: `notificar-feedback`, `alerta-saude`, `convidar-email` (convite de desafio), `avisar-email` (pedido de treinador e relatório compartilhado).
- Secrets (só nomes; valores ficam no Supabase › Edge Functions › Secrets): `RESEND_API_KEY`, `FEEDBACK_FROM`, `FEEDBACK_TO` (opcional), `CONVITE_FROM` (opcional; cai em `FEEDBACK_FROM` e depois em `onboarding@resend.dev`).
- **Estado em 16/10/2026 (print do Andre):** domínio movoapp.com.br **verificado** no Resend desde 15/10 (região São Paulo, sa-east-1). No Supabase só existiam `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET` e `ANTHROPIC_API_KEY`: **`RESEND_API_KEY` não estava criada**, então nenhum e-mail das funções saía (nem feedback nem alerta de saúde). Andre vai criar `RESEND_API_KEY`, `FEEDBACK_FROM` = `Movo <aviso@movoapp.com.br>` e `CONVITE_FROM` = `Movo <convite@movoapp.com.br>`. A chave nunca é colada no chat.
- Sem `RESEND_API_KEY` as funções respondem `enviado:false` e **não consomem o limite**.
- Remetente `onboarding@resend.dev` só entrega para o dono da conta Resend. Para enviar a qualquer pessoa o domínio movoapp.com.br precisa estar **verificado** no Resend e o remetente usar esse domínio.
- **16/10/2026 22:00:** os 3 secrets (`RESEND_API_KEY`, `FEEDBACK_FROM`, `CONVITE_FROM`) foram criados pelo Andre (confirmado por print). A chave das funções é uma chave própria `movo-funcoes`; as chaves `Supabase Movo` (SMTP de login do Auth) e `gmail-contato` são outras e não devem ser reaproveitadas. **A confirmar:** e-mail de teste chegando (Resend › Logs mostra o motivo se falhar).
- Também planejado: e-mails de login do Supabase Auth pelo domínio (SMTP próprio) em vez do Gmail pessoal.

### 2.3 Edge functions (`supabase/functions/`)
`ajustar-semana`, `alerta-saude` (pg_cron a cada 15 min), `avisar-email`, `convidar-email`, `gerar-plano` (IA, 3 gerações/mês/pessoa), `gerar-treinos`, `importar-ficha`, `importar-historico`, `notificar-feedback`, `revisar-catalogo` (diário 23h Brasília), `strava-connect`, `strava-sync`.
Deploy: pelo MCP do Supabase (`deploy_edge_function`) ou CLI. Funções novas usam `verify_jwt: true` e chamam RPCs com o JWT do usuário.

## 3. Como trabalhar com o Andre

- Respostas em pt-BR, **concisas**. Sem recapitular os passos; dizer o resultado e o próximo passo real.
- **SQL:** se o Claude roda no Supabase, só diz que rodou e deixa o arquivo no repo. Se o **Andre** precisa rodar, colar o SQL **completo** no chat.
- O MCP do Supabase cancela `apply_migration` com SQL de aparência destrutiva (`drop ...`, `delete` dentro de funções). Não contornar: usar `create or replace`/`create or replace trigger`, ou separar em arquivo e entregar ao Andre.
- Testar RPCs sem deixar rastro: `do $$ ... raise exception 'RESULT: %', out; end $$;` (a exceção desfaz tudo), trocando o usuário com `set_config('request.jwt.claims', json_build_object('sub',<uuid>,'role','authenticated')::text, true)`.
- Ambiente do Claude: sem `npm` (rede bloqueada), então **não há build local**. Checar sintaxe com `esbuild.transformSync(src,{loader:'jsx'})` (esbuild do `tsx` global em `/home/claude/.npm-global/lib/node_modules/tsx/node_modules/esbuild`). Funções puras são extraídas para scripts de node e testadas.
- Telas **não** são testadas visualmente pelo Claude: avisar isso e pedir print se algo ficar estranho.
- **Antes de dizer que algo "não existe", buscar no código** (`grep`) e na memória. Já houve erro: afirmei que o convite do aluno ao treinador não existia, e existia (`?prof=`).
- Diretores de produto/UX/design são consultados via subagentes quando o Andre pede ("chama o diretor de...").

## 4. Arquitetura do app

- `app.js` único (React 18, JSX compilado pelo esbuild), `index.html`, `sw.js` (cache/offline), `manifest.json`, `races.json`, `runner.json`.
- Dados do usuário: `localStorage` como cache + tabela `app_data` no Supabase (sessões, treinos, agenda, `display_name`...). Sincronização em nuvem após login.
- Auth: Supabase (link por e-mail). Parâmetros de convite na URL (`?desafio=`, `?treinador=`, `?prof=`, `?amigo=`) são **guardados no localStorage na abertura e removidos da URL** (v187). Sem isso, puxar para atualizar reabria o convite.
- Puxar para atualizar na Hoje = `window.location.reload()`.
- Segurança: RLS firme; regras que viram diferencial vivem em RPC/função `security definer`, não no cliente. O treinador **nunca** lê `app_data` direto, só pelas funções `coach_*` que checam vínculo e permissão.

## 5. Banco de dados (`supabase/sql/`, ordem em `supabase/ordem.txt`)

Total: 62 arquivos. Idempotentes. `setup_completo.sql` é a soma, gerada por `build_setup.py`.

Marcos recentes:
- `challenge_acertos.sql`, `challenge_formatos.sql`, `challenge_acertos_saida.sql` (prêmios; ver 6.1)
- `indicacoes.sql` (link "traga seu amigo")
- `challenge_convites.sql`, `challenge_convites_email.sql` (convite de amigo para desafio, aviso por e-mail)
- `coach_setup.sql`, `coach_setup_v2.sql`, `coach_agenda_*.sql`, `coach_admin.sql`, `coach_contato.sql` (modo treinador)
- `coach_pedido_aluno.sql` (aluno pede a treinador que já está no Movo)
- `avisos_email.sql` (log e regras dos avisos por e-mail)
- `admin_m_contas.sql` (lista de contas do painel de métricas)

## 6. Decisões por área

### 6.1 Desafios e prêmios (P1: controle de acertos, **o Movo não toca no dinheiro**)
- Tabelas: `challenges`, `challenge_members`, `challenge_checkins`, `challenge_together`, `challenge_invites`, `challenge_ledger` (livro-caixa **imutável**), `challenge_acerto_status`.
- `stakes` (jsonb): `semana`, `final` (texto), `semana_valor`, `final_valor` (R$), `semana_modo`/`final_modo` (`ultimo` = só o último paga; `pote` = todos pagam e os melhores dividem), `semana_divisao`/`final_divisao` (array de int que soma 100, 1 a 3 posições), `termos` ("true").
- Valores travam quando o desafio começa (trigger `_challenge_stakes_check`). **Sem teto de pessoas e de valores** (decisão do Andre: "não estamos lidando com o dinheiro"); só um teto técnico de R$ 100.000 por segurança de dados.
- Fechamento no servidor: semana fecha 1 dia depois do fim (fuso de São Paulo). `_challenge_close`, `_challenge_settle` (soma zero, empate divide a fatia).
- Divisão em mais de 1 prêmio exige `n0 >= len(div)+2` participantes na data de início; senão cai no modo simples. **Fallback = `[100]` (tudo para o 1º) e quem perde paga.** Interpretação ainda **não confirmada** pelo Andre.
- Tela "Acertos": paguei / recebi / perdoar / contestar (48h). Termos 18+.
- Sair do desafio fecha o que já passou antes (quem sai paga o que deve); excluir é bloqueado com acerto em aberto (`challenge_acertos_saida.sql`).
- Futuro (custódia do dinheiro): só após validação jurídica/contábil. Ver `docs/PLANO_NEGOCIO_E_PREMIOS.md`.
- Tela pré-início redesenhada (v184): contagem regressiva, avatares de quem entrou, um cartão de convite, acordeões.
- Bolinha do menu Desafios (v189): só acende para avisos **não vistos** (`treino-app:desafioAvisosVistos`, 14 dias); avisos vistos na aba ou dispensados (`desafioAvisosDispensados`) não contam.

### 6.2 Convites e indicações
- Link global "traga seu amigo pro Movo": `https://movoapp.com.br/convite/?amigo=CODE`. Tabelas `user_referral`, `user_origem.ref_code`; RPC `my_referral()`. Mostra quantos entraram e quantos treinaram. Pode servir de base para recompensas depois.
- Convite para desafio: link `?desafio=CODE`, ou pela lista de amigos (`challenge_invites`, cartão de convite recebido), ou por e-mail (`convidar-email`, quem não tem conta recebe e-mail).

### 6.3 Modo treinador
- Gate: treinador se cadastra, fica `em_analise` e é aprovado (`coach_profiles.status`: `em_analise`/`ativo`/`suspenso`). Suspender congela vínculos.
- Vínculos em `coach_links` (`pendente`, `ativo`, `pausado`, `encerrado`, `recusado`, `congelado`); 1 treinador ativo por aluno. Permissões do aluno: `ver_treinos`, `ver_cargas`, `ver_esforco_dor`, `ver_corrida`.
- Três caminhos de vínculo: (a) treinador convida (`?treinador=`); (b) aluno gera link para treinador fora do Movo (`?prof=`, `coach_student_invites`); (c) **aluno busca treinador ativo e faz pedido direto** (`coach_buscar`, `coach_pedir`, `coach_pedidos_recebidos`, `coach_pedido_recusar`; validade 14 dias, até 3 pedidos abertos, 1 por treinador, recusado bloqueia novo pedido por 7 dias). Pedido direto só é visível ao treinador escolhido e ao aluno.
- Treinador envia a semana como **proposta**; o aluno revisa o diff antes de entrar na agenda. Payload: `{dias:{0..6:[itens]}, fichas:{ref:ficha}}`; item `{tipo:"treino",ref}` ou `{tipo:"atividade",id,nome,detalhe,corrida?}`.
- **Treino de corrida estruturado do treinador (v185):** item `atividade` com `id:"corrida"` e `corrida:{modelo,titulo,distanciaKm,duracaoMin,pace,esforco,detalhes,etapas}`. Modelos prontos (`TREINOS_CORRIDA`) + edição etapa por etapa (`CoachCorridaModal`, `CoachEtapasEditor`). Aluno vê gráfico e etapas (`PlanoEtapas`); `detalhe` em texto mantém apps antigos funcionando; entra no diff e no PDF. Falta: salvar como modelo reutilizável.
- Aviso por e-mail ao treinador quando recebe pedido (v188, depende do Resend).

### 6.4 Relatórios compartilhados
- `report_shares`: aluno libera por **e-mail** com categorias (frequência, carga, peso e notas, treinos completos). Filtragem no banco (`get_shared_report`). Quem recebe vê em Configurações › "Ver relatórios". Aviso por e-mail só se a pessoa já tem conta (v188).

### 6.5 Corrida
- Treinos estruturados com etapas (`planoGerarTreinoCorrida`, `planoEtapasNorm`, `PLANO_ETAPA_TIPOS`), plano para prova (IA em `gerar-plano`), replanejar, provas colaborativas (`race_entries`, `shared_races`), favoritas, Strava.

## 7. Pendências

### Do Andre
1. Rodar `challenge_acertos_saida.sql` (sair/excluir desafio com livro-caixa). Em 16/10 ainda não estava aplicado.
2. E-mail: secrets criados em 16/10; falta só testar que um e-mail chega (pedido de treinador ou relatório compartilhado entre duas contas suas).
3. Migração de domínio: 26 pessoas nunca abriram o domínio novo, 21 sem banner; decidir `dominio_novo.redirecionar=true`; Site URL do Supabase; templates de e-mail do Supabase; tirar a lista de e-mails da tela Domínio no admin; congelar `meu-treino`.
4. Jurídico/contábil: perguntas da seção 5 de `PLANO_NEGOCIO_E_PREMIOS.md` ao contador e ao advogado; revisão legal antes de abrir recursos com dinheiro; teste de validação de venda.
5. Responder: o fallback de grupo pequeno em desafios é "tudo para o 1º e o último paga"?

### Do Claude / backlog
- Salvar treino de corrida do treinador como modelo reutilizável.
- Exportar `race_favorites` no pedido de dados (LGPD).
- Roadmap item 9: trocar o e-mail da conta.
- Aviso em tela (não só e-mail) quando alguém libera relatório para você.
- Compartilhar relatório escolhendo da lista de amigos (hoje só por e-mail).

## 8. Registro de decisões (mais recentes primeiro)

- **16/10/2026:** painel de métricas (movo-site/admin) ganhou a aba **Contas** (RPC `admin_m_contas`, arquivo `admin_m_contas.sql`): lista rolável de todas as contas, ordem por cadastro ou último acesso (recentes/antigos), busca por nome/e-mail, selos "treinou" e "você/teste", origem do cadastro. A aba Usuários da aba Admin do app continua como está (decisão do Andre: não tirar).
- **16/10/2026 (v190):** admin › aba Usuários ganhou lista compacta de contas (`AdminContas`): caixa com rolagem, ordena por **cadastro** ou **último acesso** (recentes/antigos), busca por nome ou e-mail, toque expande os detalhes. Usa os dados que o admin já carregava; sem SQL novo.
- **16/10/2026 (v189):** bolinha de Desafios conta só avisos não vistos.
- **16/10/2026 (v188):** avisos por e-mail (pedido de treinador, relatório compartilhado) via `avisar-email`; só para quem já tem conta; 15/dia; sem repetir em 7 dias.
- **16/10/2026 (v187):** parâmetros de convite saem da URL depois de guardados (corrige puxar para atualizar reabrindo o desafio).
- **16/10/2026 (v186):** aluno pode pedir a treinador que já usa o Movo (busca por nome ou e-mail exato; só treinadores ativos; mostra nome, CREF e bio).
- **16/10/2026 (v185):** treinador monta treino de corrida estruturado: "os dois": modelos prontos e edição etapa por etapa.
- **16/10/2026 (v182):** e-mail para amigo convidado e convite por e-mail para quem não tem conta.
- **16/10/2026 (v180):** desafios sem limite de pessoas e valores; fallback para grupo pequeno.
- **16/10/2026 (v179):** formatos de prêmio (semanal + final ou só final; o que cada colocação paga) seguindo a proposta do UX; link global de indicação.
- **16/10/2026 (v178):** prêmios P1 (controle de acertos, Movo não toca no dinheiro).
- **Antes:** app migrado para `app.movoapp.com.br` em repositório novo; licença proprietária; build com esbuild; domínio comprado no Registro.br; marca "Movo" sem registro conflitante nas classes 9, 41 e 45 (Cabify na 42).
- **17/10/2026 (verificado no GitHub):** o repositório antigo `meu-treino` (github.io) tem como **último build a v174** (commit de 16/10, links de convite pelo endereço estável). O `movo-app` (app.movoapp.com.br) assume a partir da **v175**. Não foi congelado na v163. O registro de versão em `app_opens` começa na v164; o campo `host` só passa a ser enviado a partir da v176.
- **17/10/2026 (painel de métricas, aba Domínio):** `_m_site(host, versao)` classifica como "antigo" a abertura sem `host` com versão menor que 175, e como "novo" a partir da v175. Portanto v173/v174 sem `host` contam como endereço antigo, o que é coerente com o corte acima. Limite conhecido: uma pessoa pode ter o ícone antigo e o novo, e a lista "Ainda no endereço antigo" mostra só a última abertura. Caso de Letícia e Maísa (17/10): abriram o novo (v190/v176) e voltaram à v174 pelo ícone antigo. **Decisão do Andre (17/10): não precisa da marca "já abriu no novo"; fica como está.**
- **17/10/2026 (v191):** versão do app exibida no fim do menu lateral (abaixo de "Sair"), além da que já existe em Configurações.
- **17/10/2026 (v192):** relato da Letícia (Android): no menu lateral, arrastar para rolar atualizava o app e ela não alcançava o fim do menu. Menu endurecido: `overscroll-behavior:contain`, `touch-action:pan-y`, `max-height:100dvh` e folga de área segura embaixo; fundo do menu sem gesto de rolagem. Não reproduzido por Claude (sem teste visual): confirmar no aparelho dela.
- **17/10/2026 (v193):** iPhone com o app instalado (PWA): o cabeçalho (com o menu) ficava por baixo da barra de status e não dava para tocar no menu (relato da Letícia). Causa: `viewport-fit=cover` + status bar `black-translucent` sem nenhum `env(safe-area-inset-*)` no topo. Corrigido com a área segura no topo do app (`.gt-shell`), nas telas cheias (`.gt-focus-header`), no menu lateral e embaixo na barra de abas. **O Andre testa no Android; iPhone só é testável por quem tem iPhone.** A v192 (menu) foi um palpite errado para esse relato.
- **17/10/2026 (landing, movo-site):** feedback de um amigo: página com scroll demais. Removida a seção "Recursos" (5 blocos com capturas de tela, repetia vídeos e vantagens), FAQ de 10 para 6 perguntas (saíram offline, planilha/outro app, Strava, quem não corre), espaçamento vertical menor. Seções agora: Como funciona, Em vídeo, Vantagens, Treinadores, Instalar, Dúvidas. Edita-se `_src/template.html` e roda `python3 _src/build.py`.
- **17/10/2026 (landing, movo-site):** a seção separada "Em vídeo" (abas + carrossel) foi removida. Os vídeos agora ficam dentro de cada seção: seção "Em ação" (id `vantagens`) com 4 linhas (ficha, treinar, desafios, corrida) e o vídeo de treinadores na seção "Para treinadores". Os 6 cards de vantagens saíram (a mensagem está nas legendas dos vídeos). O evento `video_play` continua e o CTA `pos=video` deixou de existir. Seções: Como funciona, Em ação, Treinadores, Instalar, Dúvidas. Não testado visualmente.
- **17/10/2026 (v194):** feedback de amigo no iPhone, vindo de convite de desafio: a janela "Entrar no desafio?" ficava por baixo da barra de abas (botões Entrar/Agora não sobrepostos pelos ícones). Correção: `.gt-body` com `position:relative; z-index:1` e `.gt-tabbar` com `z-index:0`, para que janelas (`.gt-modal-backdrop`, `position:fixed`) criadas dentro do conteúdo cubram a barra. Vale para todas as janelas na tela principal. Não testado em iPhone.
- **17/10/2026 (v195, decisão do Andre):** configuração inicial, passo 3: escolha única "Como montar as fichas" (Sugestão do Movo = padrão / Fichas prontas / Montar com IA; as duas últimas abrem a biblioteca ou o assistente de IA ao concluir) e, em cada dia de academia, um seletor "Trocar:" que troca a ficha de lugar com a de outro dia (a pessoa só mexe se quiser). Evento `onb_ficha_prontas|ia|sugestao` e `onb_ficha_trocada_dia`. Não testado visualmente.
- **17/10/2026 (v196, decisão do Andre):** o Strava passa a ser o último passo de tudo. Saiu o botão "Já usa o Strava? Concluir e conectar" da configuração inicial (ele mandava a pessoa para fora do app e cortava a escolha de fichas). Agora, ao concluir uma configuração nova, a aba Hoje mostra uma vez o card "Já usa o Strava?" (Conectar / Agora não), que some depois de conectar ou dispensar (`localStorage strava_convite`). O Strava continua em Configurações › Integrações e no menu.
- **17/10/2026 (Strava, pendência do Andre):** `stravaAuthorizeUrl()` usa `redirect_uri = origem + caminho` da página (hoje `https://app.movoapp.com.br/`). No painel de desenvolvedor do Strava (strava.com/settings/api, app Client ID 282598) o campo **Authorization Callback Domain** precisa ser `app.movoapp.com.br`; se ainda estiver com o domínio antigo (github.io), conectar o Strava pelo app novo dá erro de redirect_uri. Quem já está conectado continua sincronizando (os tokens ficam no servidor). Andre ainda não alterou (17/10).
- **17/10/2026 (Strava, painel do desenvolvedor):** a página é strava.com/settings/api ("Meu aplicativo API", Client ID 282598). O **Authorization Callback Domain** fica dentro do botão **Editar** (topo, ao lado de "Detalhes"); valor a usar: `app.movoapp.com.br`. **Limite do nível padrão: 10 atletas conectados** (3 conectados em 17/10). Ao passar disso, novas conexões falham: pendência do Andre pedir aumento de capacidade ao Strava (app com Privacidade e Termos públicos já existe). Considerar tratar o erro de limite no app com mensagem amigável.
- **17/10/2026 (Strava, resolvido pelo Andre):** no painel do Strava ele trocou o Authorization Callback Domain (era `dursoandre.github.io`) para `app.movoapp.com.br`, e ajustou site e descrição do app. Falta só o teste de conexão pelo app novo (Configurações › Integrações) e, mais adiante, o pedido de aumento do limite de 10 atletas.
- **17/10/2026 (roadmap, Strava):** decisão do Andre: o pedido de aumento do limite de 10 atletas fica no `ROADMAP.md` (pendências), junto com a mensagem amigável de erro de limite no app.
- **17/10/2026 (jurídico e contábil):** criado no Claude Docs o documento "Contexto do Movo para jurídico e contábil" (estado do produto, preços, prêmios fases 1 e 2, dados e terceiros, o que já existe de jurídico, checklist para o Andre preencher e dois prompts prontos para agente contábil e jurídico). Perguntas centrais: começar a cobrar só com CPF, quando abrir CNPJ e qual modelo de cobrança. Hipóteses não confirmadas marcadas no documento: Asaas exigir CNPJ e regras das lojas de apps. Uso: agentes primeiro, depois profissional humano. Atualizar o documento quando mudar preço, número de contas ou decisão de negócio.
- **17/10/2026 (canais de venda, decisão do Andre):** cobrança só pela web por enquanto, e eventualmente entrar nas lojas de app. Documento jurídico/contábil atualizado, com complemento de prompt que pede resposta nos dois cenários (web agora, lojas depois).
- **17/10/2026 (proteção do código, pendência):** `movo-app` e `movo-site` são repositórios públicos; `docs/` (negócio, prêmios, SQL) fica exposto; sem chaves secretas no código (verificado). Ver item no ROADMAP. Decisão do Andre pendente.
- **18/10/2026 (v197, decisão do Andre):** em desafio, a **distância mínima (km) vale só para corrida**; vôlei, CrossFit, Hyrox e demais atividades seguem só a regra de duração. Vale para todos os desafios, os atuais e os novos, porque a checagem é feita no app (`desafioCheckinsFromSessions`) e não depende da regra gravada. Corrida = atividade `corrida` ou nome com corrida/correr/running/rodagem/trote/maratona/longão (`desafioEhCorrida`). Causa do relato: no Projeto Verão (mín. 5 km e 30 min, exige distância) o vôlei de 18/10 (100 min, sem km) não contava. O texto "O que conta" e a criação de regras agora dizem "corrida: X km ou mais". Pendência: mostrar o motivo quando um treino não conta para o desafio.
