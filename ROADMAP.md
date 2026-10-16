# Roadmap do Movo

Lista viva do que queremos discutir e implementar, em ordem de conversa (não de prioridade). Itens concluídos saem da lista.

**Plano para abrir ao público e cobrar:** ver `docs/PLANO_APP_REAL.md` (fases 0 a 5, riscos e próximos passos). **Validação do negócio e prêmios dos desafios:** ver `docs/PLANO_NEGOCIO_E_PREMIOS.md`.

## Feedbacks novos (a discutir e implementar)

1. ~~Import de histórico de treinos~~ (feito na v88: texto, Excel, PDF, foto e WhatsApp, com revisão e desfazer).
2. **IA ajustando os treinos dentro do app** (v96: "Ajustar minha semana" feito; ver docs/PLANOS_PROXIMOS.md. Falta: tela de Evolução mostrar ajustes e aprender com o que foi aceito)
   - Ex.: quando o usuário muda ou pula um treino, ajustar os dias seguintes com base no que foi feito e no que não foi.
   - Sinais já existem: exercícios pulados, adicionados e séries alteradas no treino do dia, mais os eventos de "salvar na ficha".

3. **Calendário de provas (v1 no ar, a evoluir)**
   - Já existe: tela "Provas" (🏁 no cabeçalho), filtros, "Vou nessa", entrada manual e contagem regressiva na Hoje. Base em `races.json` (47 provas, carga manual).
   - Falta: provas marcadas/manuais sincronizarem na nuvem (hoje só no aparelho); tabela `races` no Supabase; atualização semanal por tarefa agendada; mais fontes (calendário completo do Track&Field, Circuito das Estações, Maratona do Rio/SP); links oficiais de inscrição (a maioria ainda sem link); lembretes antes da prova; ligar à IA de ajuste de treino (item 2).
   - Regra de produto: mostrar a prova mesmo sem link oficial; link só quando verificado.
   - Decisões da conversa: calendário separado do fluxo de treino (só a linha de contagem na Hoje e só com prova marcada); entrada manual para o que não estiver na base; pode copiar dados do Ahotu e corroborar com o link oficial do organizador, deixando sem link o que não achar; leitura das fontes uma vez por semana.
   - Fontes mapeadas: Hyrox (hyrox.com, running.life, roxradar), Track&Field Run Series (tfsports.com.br; a página de calendário é dinâmica, precisa dos links das etapas ou da API do app), Ahotu (listagem limitada a ~10 por página; ler por mês e por cidade), Circuito das Estações, Maratonas do Rio/SP/Curitiba.
   - Limites técnicos: a leitura só abre links que apareceram na conversa ou em buscas; a tarefa semanal terá de rodar como tarefa agendada, não como script no servidor.
   - Dúvidas abertas: UF de Bonito 21K e Summer 48K; "Run for Your Lives - SP" pode ser a corrida do Iron Maiden.
   - **Provas colaborativas (feito, precisa rodar `supabase/sql/races_cloud_setup.sql`):** marcações e km vão para `race_entries`; provas cadastradas viram `shared_races` (sem duplicar por nome+data+cidade, limite de 10/dia por pessoa, `oculta` para moderar) e todos veem "👥 N outras pessoas vão · km". Menu lateral (☰), Provas com abas Minhas/Explorar e detalhes com amigos que vão (precisa da função `race_friends` do mesmo SQL) já feitos. Metas de corrida sem inscrição (aba Metas em Provas / menu Corrida; tipos distância, tempo e hábito; uma ativa por vez) já feitas. Calendário mensal/anual (aba Calendário) e moderação no painel admin (`supabase/sql/admin_shared_races.sql`) também feitos.
   - **Execução do plano de corrida (etapas):** (1) definir o formato do plano: lista de sessões com data (tipo, distância/tempo, pace/esforço, notas), já que as fichas atuais são de musculação; (2) tela de perguntas + prompt gerado para copiar/colar (versão sem custo); (3) importar o JSON do plano e mostrar na Hoje/calendário; (4) validação por código (aumento semanal, teto do longão, redução de carga, semanas leves); (5) edge function `gerar-plano` com chave da API como segredo, limite por usuário e logs; (6) botão direto no app; (7) recalcular o plano quando a pessoa perder semanas.
   - **Status do plano de corrida:** etapas 1 a 4 feitas (formato, perguntas com recomendação de dias e aviso de conflito com a academia, prompt para copiar/colar, importação com validação, sessões na aba Hoje). Decisões: só corrida; 3 planos por mês por pessoa; liberado para todos; esforço e pace juntos; o usuário decide mesmo com avisos. Faltam: edge function `gerar-plano` com limite mensal e teto de gasto (etapa 5), botão direto (6) e replanejar (7). Para sincronizar na nuvem, rodar `alter table app_data add column if not exists planos jsonb default '[]'::jsonb;`.
   - **IA no plano de corrida (etapas 5 e 6 escritas):** edge function `supabase/functions/gerar-plano` + SQL `supabase/sql/plan_generations_setup.sql` (3 gerações/mês por pessoa, devolve a reserva se a IA falhar) e botão "Gerar plano com IA" no app, que só aparece depois do SQL rodado. Pendente do lado do Andre: rodar o SQL, criar o secret `ANTHROPIC_API_KEY` (feito) e publicar a função. Depois: replanejar (etapa 7) e mostrar o consumo no painel admin.
   - **Replanejar (etapa 7 feita):** convite na Hoje quando metade ou mais das sessões das últimas 2 semanas ficou sem registro (conta corrida registrada/Strava como feita) ou quando a data da prova mudou; botão "Replanejar a partir de hoje" no plano; o prompt leva o histórico do plano anterior e pede retomada gradual; o que já passou é mantido. Consumo da IA no painel admin feito (`supabase/sql/admin_plan_usage.sql`).
   - **Visão de calendário (pedido):** ver as provas (e, no futuro, desafios e treinos) em formato de calendário mensal e anual, para se programar com antecedência. Ideia: grade mensal com marcadores nos dias de prova e visão anual com os meses e a densidade de provas; toque no dia abre os detalhes.
   - **Plano de treino para a prova (pedido):** ao marcar "Vou nessa" numa prova de corrida, mostrar um botão "Criar plano de treino". O plano considera: distância que a pessoa corre confortável hoje (puxar do histórico/Strava e confirmar com ela), distância da prova, objetivo (completar ou baixar tempo/pace), semanas até a prova e dias disponíveis por semana. Saída: fichas semanais (rodagens, longão, intervalado, descanso, polimento nas últimas semanas) que entram no calendário e na aba Treino. Depende do item 2 (IA ajustando treinos) e de uma tela rápida de perguntas; com pouco tempo até a prova, o app deve avisar que o prazo é curto e propor meta mais conservadora.

4. **Desafios (v1 construída; precisa rodar o SQL)**
   - Já existe: aba Evolução > Ranking > "Desafios" (o ranking antigo virou "Geral"). Criar desafio em 3 passos (modelos meta/café/simples, regras editáveis, aposta semanal e final), convite por código ou link `?desafio=CODE`, check-ins automáticos (academia + atividades do app, no máximo 1 por tipo por dia), "treinei com alguém" com confirmação do outro, pista de corrida animada, placar, semanas fechadas com vencedor/perdedor, cartão 1080x1350 para compartilhar, chip na Hoje.
   - Ativação: rodar `supabase/sql/challenges_setup.sql` no SQL editor do Supabase. Até lá a aba mostra "ainda não foram ativados".
   - Regras configuráveis por desafio: academia/atividades (mínimo de minutos, mínimo de exercícios, só atividades por nome), limite de treinos por dia (inclui "dia ativo"), dias da semana que valem, exigir duração. Só o criador edita; regras travam quando o desafio começa; semana começa na segunda (configurável).
   - Engajamento (feito): avisos nos desafios (semana fechou com quem ganhou/paga e cartão pra compartilhar, "fulano te passou", "você assumiu a liderança", "fulano já bateu a meta", lembrete quando faltam até 2 dias e a meta não foi batida, fim do desafio), ponto vermelho na aba Desafios, aviso no chip da Hoje, gráfico "corrida dos pontos" (acumulado por semana) com cartão pra compartilhar.
   - Strava (feito): regra "distância mínima (km)" e "exigir distância registrada". A distância vem do campo `distanciaKm` da carga (a função `strava-sync` atualizada precisa ser reimplantada no Supabase) ou, nas importações antigas, do texto "· 12.3 km ·" do comentário; também lê "5 km" digitado no comentário.
   - Falta: notificações push de verdade (precisa de Web Push: chaves VAPID, tabela de assinaturas e uma Edge Function agendada; no iOS só funciona com o app instalado na tela inicial), foto como comprovação, controle de "quem deve café", unir chips de desafio e prova na Hoje, caso de empate no cartão (um aparece como 1º e o outro como 2º).
   - **Linha do tempo do desafio (feito na v165; v166 mostra só o último dia e abre de 10 em 10):** feed na tela do desafio, agrupado por dia (Hoje, Ontem, data), com filtro "Todos / Só eu" e "Ver mais". Mostra check-ins ("Rafa treinou na academia e ganhou +2 pts", com horário quando é do mesmo dia), "Faltam N pra bater a meta e passar fulano" no treino mais recente de quem ainda não bateu a meta da semana, liderança assumida, meta batida, treino junto confirmado, semana fechada, início e fim do desafio. Reação 👏 em treinos dos outros (um toque liga/desliga, contador). Só entra o que conta pontos (nunca cargas ou fichas). **Precisa rodar `supabase/sql/challenge_timeline.sql`** (horário do check-in e reações); sem ele o feed funciona, só sem horário e sem o 👏. Ideias futuras: aviso quando alguém aplaude seu treino, mais reações (🔥💪), comentário curto.

5. **Repositório privado, build e proteção contra cópia (a decidir)**
   - Feito: licença proprietária (`LICENSE`, "todos os direitos reservados") e avisos de copyright no README, `index.html` e `app.js`.
   - GitHub Pages com repositório privado exige plano pago (Pro/Team/Enterprise Cloud; conferir preço e regra atuais). O site continua público mesmo com o repositório privado. Alternativa grátis: Cloudflare Pages (também Netlify/Vercel), conectando ao repositório privado.
   - Build minificado: hoje não existe build, o `index.html` compila o JSX no navegador com o Babel. Fazer junto com a migração de hospedagem: esbuild gerando `app.min.js` no deploy, ajuste do `sw.js` e do `index.html`, sourcemaps fora do site público para os erros de `client_errors`. Ganhos: abertura mais rápida no celular e uma dependência externa a menos (Babel via CDN). Riscos: deploy depende do build; cache do service worker.
   - Mudar de endereço exige atualizar a URL de redirecionamento do login no Supabase e o domínio autorizado no Strava; os usuários teriam de reinstalar o PWA.
   - Antes de privar o repositório: varrer o histórico do Git atrás de chaves secretas (`service_role`, secret do Strava).
   - Proteção real está no servidor: RLS firme, e mover para RPC/Edge Function qualquer regra que vire diferencial (hoje os pontos dos Desafios são calculados no cliente). Código se copia; dados, curadoria e comunidade não.
   - Não publicar o que não precisa estar no site (ex.: ROADMAP.md).

6. **Revisão do catálogo de exercícios (feito na v162)**
   - O catálogo mora no banco (`supabase/sql/catalogo_banco.sql`). Todo dia às 23h (Brasília) a função `revisar-catalogo` compara os nomes de `exercise_suggestions` com o catálogo e a IA propõe alias / novo / ignorar. Você aprova ou reprova em Admin > Catálogo; ao aprovar, o app de cada pessoa atualiza as fichas dela. Detalhes em `docs/PLANO_APP_REAL.md` (v162).
   - Vídeo de execução só com link verificado (a IA não inventa vídeo; você cola na aprovação).

7. **Favoritar corridas e capítulo de corrida (depois da migração do domínio/app)**
   - FEITO (v173): favoritar provas (☆/★ no card e no detalhe), aba "Favoritas" em Provas com data, link da inscrição e aviso quando faltam ≤45 dias e a pessoa ainda não marcou "Vou nessa". Sincroniza na tabela `race_favorites` (`supabase/sql/race_favorites.sql`). Pendente: incluir favoritas no export LGPD (`export_my_data`); lembrete por notificação (hoje é só aviso dentro do app, pois o app não sabe a data de fim das inscrições).
   - Avaliar um capítulo próprio só de corrida (provas favoritas, inscrições, metas, plano de treino, histórico), reunindo o que hoje está espalhado entre Provas, menu Corrida e Hoje.
   - Sincronizar na nuvem junto com `race_entries` (estado "favorita" separado de "vou").
   - Só começar depois de resolvida a migração para movoapp.com.br.

8. **Prêmios dos desafios: acerto de contas e custódia do dinheiro (a planejar com muito cuidado, lida com dinheiro dos outros)**
   - Plano completo em `docs/PLANO_NEGOCIO_E_PREMIOS.md` (inclui o mapa do que já temos, o que temos mais ou menos e o que não temos, a partir da conversa com o Lucas em 16/10/2026).
   - **Fase P1, controle de acertos (sem o Movo tocar em dinheiro):** valores em reais estruturados (por semana e final), fechamento e lançamentos calculados no servidor (imutáveis), tela "Acertos" com quem deve o quê para quem desde o começo, valor final de premiação e quem paga nos desafios com prêmio, confirmação "paguei"/"recebi", contestação com prazo, regra de saída. Hoje a aposta é texto livre.
   - **Fase P2, gestão real do dinheiro (receber, segurar até o fim e liberar):** só com CNPJ, parecer jurídico, parceiro licenciado (retenção e split) e piloto fechado com valores baixos e liberação aprovada por você. O Movo nunca segura dinheiro de terceiros em conta própria. Só Pix no começo, interruptor geral, reconciliação diária, trilha de auditoria.
   - Rendimento do dinheiro em custódia (a "caixinha 100% CDI" da conversa) e taxa sobre o pote: possível fonte de receita, mas não entra em projeção até o parecer jurídico.
   - Pré-requisito técnico: mover o cálculo de pontos dos Desafios do aparelho para o servidor (ver item 5).
   - Perguntas abertas para contador e advogado: seção 5 do plano.

9. **Trocar o e-mail da conta (hoje não existe)**
   - Situação: o login é só por código ou link no e-mail (sem senha) e o cadastro nasce dele. Quem entrar com outro e-mail cria uma conta nova e vazia (sem treinos, desafios, amigos nem Strava). Os dados ficam presos ao `user_id` do Supabase, que não muda; o e-mail é só a forma de entrar.
   - Desenho: Configurações > Conta > "Trocar e-mail". A pessoa digita o novo e-mail, confirma o código enviado a ele (e, por segurança, também a confirmação no e-mail antigo) e a conta passa a usar o novo, mantendo o mesmo `user_id` (`supabaseClient.auth.updateUser({ email })`, com "Secure email change" ligado em Authentication > Providers > Email).
   - Pontos que guardam o e-mail e precisam ser migrados ou invalidados na troca: convites de amizade pendentes (`friend_requests.from_email`/`to_email`), compartilhamento de relatórios (`report_shares.owner_email`/`viewer_email`), vínculos e convites de treinador, `user_consents` se tiver e-mail, e o e-mail admin (`ardurso@gmail.com`, função `is_movo_admin`).
   - Segurança: exigir sessão recente, confirmar nos dois e-mails, registrar o evento (`app_events`), avisar o e-mail antigo e rate limit contra abuso. Atualizar a exportação LGPD (`export_my_data`) se algo novo for guardado.
   - Casos de borda: e-mail novo já existe em outra conta (recusar e orientar), pessoa perdeu acesso ao e-mail antigo (suporte manual por enquanto, com verificação de identidade), troca durante desafio ou vínculo ativo.
   - Prioridade: a definir. Não entra junto com a migração de domínio.

## Em planejamento: agenda e pacotes do treinador

Plano completo em `docs/PLANO_AGENDA_TREINADOR.md`: aba nova "Agenda" (compromissos dia a dia, horário livre derivado da janela de trabalho, aula particular, coletiva, treino próprio), alunos da agenda só com nome (vínculo com perfil real quando o aluno aceita o convite, confirmado pelo treinador) e pacote de aulas com saldo automático. Cobrança fica para depois.

## Backlog do modo treinador (avaliar depois)

Itens levantados pelo time de UX/PM em 13/10/2026 e deixados de fora da agenda por enquanto:

- **Alerta de abandono com ação de um toque**: no cartão do aluno que está esfriando, botão "Chamar no WhatsApp" com mensagem pronta.
- **Atalhos de WhatsApp**: convite, treino enviado, lembrete de convite pendente, copiar três horários livres para responder um aluno.
- **Montar a semana em lote**: enviar a mesma semana a vários alunos e repetir a semana passada para quem não mudou.
- **Atividade com ações**: respostas rápidas ("Boa!", "Reduz a carga", "Me chama") e nota por ditado após a sessão.
- **Compartilhar a semana por link ou imagem** para o aluno que ainda não aceitou o convite.
- **Onboarding em lote de alunos**: colar vários nomes de uma vez e gerar os convites.
- **Resumo semanal do treinador**: quem treinou, quem faltou, cargas novas.
- **Cobrança e pagamento**: mensalidade e pacote (decisão de negócio adiada; depende de pacotes em uso).
- **Notificações push**: lembretes de aula e presença pendente; hoje só existe aviso dentro do app.
- **Exportar a agenda para calendário (.ics)** e **sincronizar com o Google Agenda** (ler horários ocupados e/ou escrever os compromissos).
- **Aluno ver as próprias aulas** agendadas pelo treinador, com lembrete.
- **Aula coletiva com lista de presença** (participantes, vagas, lista de espera).
- **Auto-agendamento e página pública de reserva.**
- **Biblioteca de exercícios com vídeo de execução** (hoje só link verificado).
- **Telefone no perfil: pontos a decidir antes de lançar** (plano em `docs/PLANO_AGENDA_TREINADOR.md`, §3.3): valer para todos os usuários (com ou sem treinador), pedido como campo opcional no onboarding e em Configurações; texto de apoio dizendo que é só para o treinador falar com o usuário e para avisos da conta, nunca propaganda; permissão `ver_contato` do aluno (ligada por padrão?) para o treinador ver o número e abrir o WhatsApp; canal de "avisos da conta" ainda não existe (revisar o primeiro uso); tabela `user_contact` com RLS; incluir na exportação e na exclusão de conta; atualizar `privacidade.html` e os termos; uso interno para sugerir vínculo sem expor o número ao treinador.
- **Pesquisa com 8 a 10 personais brasileiros** (cobram por pacote, mensalidade ou aula avulsa? presencial ou online?) para calibrar as próximas apostas.

## Ideias futuras (sem data)

- **Avaliação de treinadores**: os alunos avaliarem o treinador (nota e comentário), com regras contra abuso (só quem teve vínculo ativo avalia, uma avaliação por vínculo, treinador pode responder, admin pode moderar).
- **Marketplace de personais**: alunos buscarem treinadores dentro do app (perfil público opcional, especialidade, avaliação, convite/solicitação de vínculo). Hoje o perfil do treinador só é visível pra quem recebe ou aceita um convite; o marketplace exigiria um perfil público opt-in, e revisar termos, privacidade e o fluxo de aprovação do admin. Depende de ter base de treinadores ativos e do tema de negócio (cobrança), que está adiado.

## Pendências de coisas já conversadas

- **Ajustes no treino de hoje (entregue)**: falta rodar `supabase/sql/app_events_setup.sql` e `supabase/sql/admin_login_stats.sql` no Supabase para o painel admin mostrar as medições (treinos com ajuste, quanto salvam na ficha). Sem isso o app funciona normal, só as seções de medições e de logins por usuário não aparecem.
- **Onboarding sem "1x por semana"**: só existe 0 e 2 a 7. Adicionar se fizer sentido.
- **Strava**: limite da API é por aplicativo (~100 req/15 min, ~1.000/dia). Pode virar gargalo se a base crescer.
- **Supabase plano grátis**: 500 MB de banco (já monitorado no painel admin) e pausa do projeto após 1 semana sem nenhuma atividade.

## Proposta: como importar histórico de treinos

O histórico vive em `sessions[data].log["treino:<id>"][<exercício>].sets[{peso, reps}]`, mais `cargas` (duração, RPE, dor). Importar = gerar essas entradas com data e vincular a um exercício/ficha do app.

Caminhos possíveis, do mais simples ao mais ambicioso:

1. **CSV de outros apps (Strong, Hevy etc.)**: parser por formato conhecido, tela de pré-visualização e mapeamento de nomes de exercício (o nome deles raramente bate com o nosso catálogo).
2. **Planilha/texto livre colado, interpretado por IA**: igual ao import de fichas que já existe (prompt + JSON), mas com datas, cargas e reps. É o mais flexível e o mais barato de construir.
3. **Foto/print do histórico**: IA lê a imagem e devolve o mesmo JSON do caminho 2.

Decisões a tomar antes: o que fazer quando o exercício importado não existe no app (criar ficha "Histórico importado" ou casar com o catálogo?), e como evitar duplicar dias que já têm registro.

## Backlog do modo treinador: importar ficha com várias semanas (periodização)

Hoje o "Importar ficha" (v161) lê só a **primeira semana/fase** quando o documento traz um bloco periodizado (ex.: mesmo treino em 4 semanas com séries, repetições ou cargas que mudam semana a semana, ou fases como adaptação, força e deload) e avisa. Item futuro: importar todas as semanas, criando uma semana no compositor para cada uma (hoje o compositor é de uma semana por envio) ou um bloco de semanas enviadas em sequência, com a progressão visível ao aluno. Depende de decidir como o app representa progressão por semana (um envio por semana ou um "mesociclo" com datas).
