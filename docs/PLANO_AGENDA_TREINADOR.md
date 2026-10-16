# Plano: agenda e pacotes de aulas do treinador

Status: **proposta revisada com as decisões do dono (13/10/2026)**, pronta para revisão final. Substitui o parecer anterior de UX/PM, que dizia "só exportar". Cobrança e pagamento ficam fora (ver `ROADMAP.md`, seção Backlog do modo treinador).

## 0. Decisões já tomadas
1. **Aba nova "Agenda"** no modo treinador (não substitui Atividade).
2. **A agenda vive dentro do app.** Exportar para calendário não resolve: o treinador não usa app de calendário. Tudo fica no Movo: aula particular, aula coletiva, treino próprio, horário livre e outros compromissos.
3. **O treinador planeja sem o aluno estar no app.** O aluno entra na agenda só com o nome. Se depois aceitar o convite, o app pergunta se é a mesma pessoa e vincula.
4. **Pacote de aulas combinado com cada aluno**, com saldo de aulas restantes calculado sozinho.
5. **Cobrança fica para depois.**
6. Tratamos o restante dos itens levantados como backlog (nada disso entra agora).

## 1. Hipótese e critério de sucesso
**Hipótese:** se o treinador organizar a semana inteira (aulas, horários livres, treino próprio) no Movo, ele abre o app todo dia, e isso traz o aluno para dentro (vínculo com perfil real).

**Sucesso do piloto (calibrar com a Dayanne e pelo menos um treinador sem relação prévia):**
- Abre a aba Agenda em 4 de 5 dias úteis, na semana 2 em diante.
- Cadastra a própria semana sozinho, em menos de 3 minutos para 10 compromissos usando recorrência.
- Marca presença/falta em pelo menos 70% das aulas passadas.
- Diz que deixou de usar caderno/Google Agenda para esses compromissos. Se mantém os dois, a agenda é duplicidade e não vale seguir.
- Pelo menos metade dos alunos da agenda recebe o convite do Movo em 30 dias.

**Falha:** só cadastra na primeira semana; registra os horários mas não marca presença; mantém outra agenda em paralelo.

## 2. Conceitos
- **Compromisso**: algo na agenda. Tipos: `particular` (aula com um aluno), `coletiva` (turma), `treino_proprio`, `outro`. Cada um tem título automático (nome do aluno ou do tipo), dia, hora e duração.
- **Horário livre**: nunca é cadastrado. O treinador define uma vez a **janela de trabalho** (ex.: seg-sex 6h-12h e 16h-21h). Livre = janela menos compromissos. Aparece em cinza na linha do tempo. Bloqueio pontual (almoço, viagem) é um compromisso do tipo `outro`.
- **Aluno da agenda**: pessoa que o treinador anota, com ou sem Movo. Nome obrigatório; **e-mail e telefone opcionais** (o treinador só preenche se quiser). Quando vinculado, aponta para o vínculo real (`coach_links`). É a mesma ficha de "novo aluno" usada no convite (ver §3.1): cadastrar o aluno uma vez serve para agenda, pacote, treino e convite.
- **Pacote**: combinado com um aluno da agenda (ex.: 12 aulas, válido por 60 dias). Saldo = total − aulas realizadas (− faltas, se o pacote definir que falta desconta).
- **Ocorrência**: cada aula numa data. Compromissos recorrentes geram ocorrências; cada uma tem status `agendada`, `feita`, `faltou`, `remarcada` ou `cancelada`.

## 3. Experiência (mobile, uma mão, em pé)
### Navegação
Abas: Alunos | **Agenda** | Atividade | Modelos | Perfil. Se cinco abas ficarem apertadas, Perfil passa para o menu do chip de perfil. Avaliar no protótipo.

### Tela Agenda
- Topo: tira de 7 dias (hoje destacado, ponto nos dias com compromisso), setas para semanas, botão "Hoje".
- Corpo: **lista do dia** em linha do tempo vertical. Cada item mostra hora, nome, tipo (ícone + cor suave) e, para aula de aluno com pacote, "aula 4 de 12".
- Buracos livres aparecem como linhas cinzas ("Livre 10h-11h30"). Toque no buraco abre o "+" já preenchido com aquele horário.
- Visão **Semana** opcional (alternador), somente leitura, mostrando blocos ocupados e livres. A edição fica na lista do dia.
- Estado vazio: "Monte sua semana" com 3 atalhos: cadastrar o primeiro compromisso, definir a janela de trabalho, copiar a semana anterior.
- Ao passar o horário de uma aula sem marcação, o dia ganha um selo "Marcar presença (2)" no topo da lista e um ponto na aba. Sem push por enquanto: o aviso vive dentro do app.

### Cadastrar (quatro toques, tudo pré-preenchido)
1. **+** (ou toque num buraco livre). Horário em seletor de roda, padrão a próxima hora cheia ou o buraco tocado.
2. Tipo e pessoa: chips `Particular | Coletiva | Treino meu | Outro`. Em Particular, escolher da lista de alunos da agenda ou "Novo aluno" (digita só o nome).
3. Repetição por chips: `Só este dia | Toda semana | Seg-Qua-Sex`, com dias editáveis. Duração padrão de 60 min (chips 30/45/60/90), configurável no perfil.
4. Salvar.

Sem campos de local, preço ou serviço.

### Marcar presença e remarcar
Tocar num compromisso abre a folha com **Aconteceu | Faltou | Remarcar** (um toque cada), mais editar e cancelar. Remarcar escolhe nova data e hora e preserva a ocorrência original como `remarcada`. Em compromissos recorrentes, editar/cancelar pergunta "Só esta | Esta e as próximas".

### 3.1 Aluno, convite e vínculo
**Fluxo principal (decisão 13/10): cadastrar o aluno gera o código.**
1. O treinador cria o aluno (nome; e-mail e telefone opcionais). Ele entra na agenda e na lista de Alunos como "Convite pendente".
2. O app gera o **código/link de convite já amarrado a esse aluno**. O treinador compartilha pelo WhatsApp (botão que abre a conversa pelo telefone, se preenchido).
3. **Enquanto o aluno não entra, o treinador trabalha normalmente:** agenda, pacote, presença e montagem do treino (rascunho). Hoje o composer só abre para vínculo ativo; será liberado para o aluno com convite pendente. A semana preparada fica guardada e é entregue ao aluno quando ele aceitar, sem sobrescrever nada dele.
4. O aluno entra com o código, vê a tela de consentimento de sempre e escolhe as permissões. Como o código pertence àquele aluno da agenda, **o vínculo é automático**: aulas passadas e futuras, pacote e rascunhos passam a apontar para o perfil real. Não precisa perguntar nada ao treinador.

**Fluxo de reserva (sugestão por correspondência):** vale quando o aluno chega por um convite genérico (sem aluno da agenda amarrado) ou por um código antigo. O servidor compara, **no banco e sem expor os dados do aluno ao treinador**, o perfil que aceitou com os alunos da agenda sem vínculo:
- e-mail igual (normalizado) → correspondência forte;
- telefone igual (só dígitos, sem 55 e sem zero à esquerda), quando o aluno tiver informado o telefone (§3.3) → forte;
- nome parecido (sem acento e maiúsculas, mesmo primeiro nome e sobrenome) → fraca, só sugere.
O treinador recebe "João aceitou seu convite. É o João da sua agenda?" com o que será ligado, e confirma ou escolhe outro. Correspondência fraca nunca vincula sozinha. Sem correspondência, nada acontece e o aluno entra como aluno novo.

- Vinculado, o compromisso abre o perfil do aluno com a semana de treino ("Enviar/ajustar semana").
- Na aba Alunos, o cartão do aluno vinculado mostra o saldo do pacote.

### 3.3 Telefone opcional no perfil (decisão 13/10)
- **Para quem:** qualquer usuário, treine com treinador ou sozinho (modo "Meu treino"), não só aluno de alguém.
- **Onde pedir:** no onboarding, como último campo opcional com "Pular" bem visível; e em Configurações > Perfil, onde pode ser preenchido, editado ou apagado a qualquer momento.
- **Texto de apoio (sutil, abaixo do campo):** "Opcional. Usamos só para o seu treinador falar com você, se você tiver um, e para avisos da sua conta. Nunca para propaganda." Não menciona vínculo. Para a política de privacidade e os termos, a finalidade é a mesma.
- **O que o texto promete (e o app precisa cumprir):**
  1. Sem marketing: nenhum envio promocional por esse número, e nunca repassar a terceiros.
  2. "Contato do seu treinador": se houver vínculo ativo, o treinador passa a ver o telefone e pode abrir o WhatsApp. Isso é uma **permissão do aluno** (`ver_contato`, ligada por padrão, com opção de desligar na tela de permissões do vínculo). Sem vínculo, ninguém vê.
  3. "Avisos da sua conta": hoje o app não envia SMS nem WhatsApp. Só prometer o que entregamos; se esse canal ainda não existir, o texto continua verdadeiro, pois descreve a finalidade, e o primeiro uso (ex.: aviso de segurança) passa por revisão.
- **Uso interno (não aparece no texto):** o servidor também usa o número para sugerir o vínculo com o aluno cadastrado pelo treinador. Isso cabe na finalidade "contato do treinador" e não expõe o número a ninguém.
- **Onde guardar:** o nome do perfil hoje vai no `app_data` (JSON sincronizado pelo cliente), que o servidor não consulta. Telefone precisa de coluna própria: `user_contact(user_id, telefone, atualizado_em)` com RLS só do dono; a leitura pelo treinador e pela correspondência passa por RPC `security definer` que checa vínculo ativo e `ver_contato`. Guardar normalizado (só dígitos, com DDD).
- **LGPD:** finalidade explícita no campo, preenchimento voluntário, apagar o campo apaga o dado, entra em `export_my_data` e na exclusão de conta, e atualizar `privacidade.html` e os termos.
- **Validação:** número brasileiro com 10 ou 11 dígitos; sem confirmação por SMS (o dado só sugere vínculo, nunca vincula sozinho).

### 3.2 Ficha em PDF para quem não entra no app
O treinador gera o PDF da semana (ou de uma ficha) e envia pelo WhatsApp com o compartilhar do Android. Cabeçalho com nome e foto do treinador, dia a dia com exercícios, séries, repetições, carga e observações, e no rodapé o **link/QR de convite do aluno**: o PDF vira porta de entrada para o app. Gerado no aparelho, sem enviar nada a servidor; não inclui dados de saúde. Fica em "Mais ⋯" no composer e na ficha do aluno, funciona também para aluno sem Movo.

### Pacote
Campos: total de aulas, validade opcional (dias), "falta desconta?" (padrão: sim), observação curta. O saldo é calculado a partir das ocorrências. Renovar cria novo pacote e mantém o histórico. Aviso na ficha e no cartão quando restar 2 aulas ou menos, ou quando faltar 7 dias para vencer. Sem cobrança nem valores por enquanto.

## 4. Modelo de dados (Supabase, RLS ligado, acesso por RPC `security definer`)
- `coach_agenda_pessoas(id, coach_id, nome, email null, telefone null, link_id null, criado_em)`: aluno da agenda; `link_id` preenchido ao vincular. Dado do treinador, visível só a ele. `coach_links` passa a poder apontar para a pessoa que gerou o convite (`pessoa_id`), o que torna o vínculo automático quando o aluno entra com o código.
- `coach_agenda_itens(id, coach_id, tipo, pessoa_id null, titulo null, hora_inicio, duracao_min, dias_semana int[] ou data_unica, inicio_em, fim_em null, criado_em)`: o compromisso, com recorrência semanal simples.
- `coach_agenda_ocorrencias(id, item_id, data, status, nova_data null, nova_hora null, nota null)`: só existe quando há exceção ou marcação (presença, falta, remarcação, cancelamento). A agenda do dia combina os itens recorrentes com as exceções.
- `coach_pacotes(id, coach_id, pessoa_id, total, validade_dias null, falta_desconta bool, inicio_em, encerrado_em null, obs)`
- `coach_agenda_config(coach_id, janela jsonb, duracao_padrao)`: janela de trabalho e padrões.
- Correspondência: `agenda_sugerir_vinculo(p_link)` roda como `security definer`, compara e-mail, telefone e nome do aluno que aceitou com as pessoas sem vínculo do treinador e devolve só `pessoa_id` e nível de confiança, nunca o e-mail ou telefone do aluno.
- RPCs: `agenda_dia/semana(p_inicio, p_fim)` (já devolve itens expandidos, buracos e selos pendentes), `agenda_item_salvar/apagar`, `agenda_ocorrencia_marcar`, `agenda_pessoa_salvar`, `agenda_pessoa_vincular(p_pessoa, p_link)`, `agenda_pacote_salvar`, `agenda_saldo(p_pessoa)`.
- **Horário:** guardar data e hora locais (America/Sao_Paulo), sem fuso, porque o público é brasileiro e a agenda é presencial. Se surgir treinador com alunos em outros fusos, revisar.
- **Sem exceção por data complexa na primeira versão:** a recorrência é semanal; exceções entram como ocorrência individual.

## 5. Privacidade (LGPD)
- Aluno da agenda não aceitou nada: guardamos nome e, **se o treinador quiser, e-mail e telefone** (campos opcionais, usados só para convidar e para sugerir o vínculo). Sem saúde e sem observações livres sobre o aluno; o campo "obs" do pacote avisa que não é para dado sensível. Telefone e e-mail têm texto de apoio: "só preencha se o aluno concordar em ser contatado".
- A correspondência não revela e-mail nem telefone do aluno ao treinador. O telefone só aparece depois do vínculo, e se o aluno mantiver a permissão `ver_contato` (§3.3).
- Visível apenas ao treinador; apagável por ele; entra na exportação de dados do treinador (`export_my_data`).
- Termos: o treinador responde pelo que cadastra de terceiros. Acrescentar uma linha nos termos do treinador.
- Ao vincular, o treinador passa a ver dados do aluno **somente conforme as permissões que o aluno já controla**. A agenda não amplia o acesso.
- Aluno que apaga a conta: o `link_id` da pessoa na agenda é desfeito e a pessoa vira só nome.
- O aluno **não vê** a agenda do treinador nesta fase.

## 6. Entrega em fases (atrás de flag, como o resto do modo treinador)
**Fase 1: Agenda básica.** Aba, tira de 7 dias, lista do dia, "+" em 4 toques, recorrência semanal, janela de trabalho, buracos livres, visão semana somente leitura, tipos.
**Fase 2: Alunos da agenda e presença.** Pessoas, selo de presença pendente, Aconteceu/Faltou/Remarcar, editar "só esta/esta e as próximas".
**Fase 3: Pacotes.** Cadastro, saldo automático, avisos de saldo baixo e vencimento, saldo no cartão do aluno.
**Fase 4: Convite e vínculo com perfil real.** Cadastro do aluno com contato opcional, telefone opcional para todos os usuários (onboarding e Configurações), código amarrado ao aluno, vínculo automático ao entrar, sugestão por e-mail/telefone/nome como reserva, composer liberado para convite pendente, abrir o perfil do aluno a partir do compromisso.
**Fase 5: Ficha em PDF** com link/QR de convite.

Cada fase é testada com os mocks do harness (como a v139+) e com testes SQL no Postgres local. Antes da fase 1, 20 minutos com a Dayanne vendo como ela organiza a semana hoje, e um protótipo de 3 telas (Agenda, "+", ficha do aluno) para o teste cronometrado. Medir desde o dia 1: abertura da aba por dia, compromissos cadastrados, % de presenças marcadas, alunos da agenda convidados e vinculados.

## 6.1 Andamento
- **Fase 1 (v144):** entregue.
- **Fase 2 (v145):** entregue. Alunos da agenda (nome, telefone e e-mail opcionais), presença (aconteceu/faltou, com selo e badge na aba), remarcar (a aula original fica "remarcada" e nasce uma aula avulsa na nova data), editar "só esta" e "esta e as próximas", lista de alunos da agenda com contagem de aulas e faltas. SQL em `supabase/sql/coach_agenda_v2.sql`. Presença só até hoje; aluno apagado mantém as aulas com o nome em texto; coletiva ainda sem lista de presença.
- **Fase 3 (v146):** entregue. Pacote de aulas por aluno da agenda (total, validade opcional em dias, falta desconta ou não, observação curta), saldo calculado das presenças desde o início do pacote, renovar (o anterior fecha na véspera e fica no histórico), editar, encerrar e apagar. Avisos: resta 2 aulas ou menos, acabou, vence em 7 dias ou menos, vencido; aparecem na lista de alunos, no detalhe da aula e numa faixa na Agenda. SQL em `supabase/sql/coach_agenda_v3.sql`; `export_my_data` passou a incluir alunos da agenda e pacotes. Pendente: saldo no cartão da aba Alunos (depende do vínculo, fase 4) e "aula 4 de 12" na linha do dia.
- **Fase 4a (v147):** entregue. Na ficha do aluno da agenda, "Convidar para o Movo" cria o convite já amarrado ao aluno (`coach_agenda_pessoas.link_id`), com código, WhatsApp (abre pelo telefone, se houver) e copiar. O convite reaproveita o código enquanto vale; expirado ou encerrado gera outro. Quando o aluno aceita pelo fluxo de sempre, o vínculo já está feito (lista mostra "No Movo" e o botão "Abrir aluno" leva ao perfil na aba Alunos). SQL em `supabase/sql/coach_agenda_v4.sql`.
- **Fase 4b (v148):** entregue. O treinador monta a semana de quem tem convite pendente (botão "Montar treino" no convite pendente e na ficha do aluno da agenda); o composer vira "Guardar para X", a semana fica no vínculo (até 20 versões, convite não expirado) e aparece para o aluno quando ele aceita. SQL em `supabase/sql/coach_agenda_v4b.sql` (só troca a checagem de `coach_send_assignment`).
- **Fase 4c (v149):** entregue. Telefone opcional para qualquer usuário: campo no último passo do onboarding e em Meu perfil (aviso: só para o treinador, se houver, e avisos da conta; nunca propaganda), tabela `user_contact` (só por RPC), permissão nova `ver_contato` no vínculo (ligada por padrão na tela do aluno; ausente = desligada em vínculos antigos), botão "Chamar no WhatsApp" na ficha do aluno para o treinador, exportação de dados e política de privacidade 1.1 (telefone e modo treinador). SQL em `supabase/sql/coach_contato.sql`. A versão de consentimento do app (`CONSENT_VERSAO`) não foi alterada, então ninguém é obrigado a aceitar de novo.
- **Fase 4d (v150):** entregue. Quando um aluno entra por convite genérico, o servidor compara (sem mostrar e-mail nem telefone do aluno) com os alunos da agenda sem vínculo: e-mail igual ou telefone igual = forte, nome igual ou primeiro e último nome iguais = fraca. A Agenda mostra "Fulano entrou no Movo. É o Fulano da sua agenda?" e só o treinador confirma; "Nenhum deles" guarda o par como ignorado neste aparelho. Também dá pra ligar manualmente pela ficha do aluno ("Já está no Movo? Ligar a um aluno"). SQL em `supabase/sql/coach_agenda_v4d.sql`. (antigo texto:) sugestão de vínculo por e-mail/telefone/nome para quem entra por convite genérico.
- **Fase 5 (v151):** entregue. No composer, "Mais ⋯" → "Gerar PDF da semana": PDF A4 gerado no aparelho (sem biblioteca nem servidor), com nome do aluno, treinador, dia a dia (séries, repetições, carga, observações). Convite pendente: rodapé com link, código e QR (gerador de QR próprio, validado lendo o QR do PDF com OpenCV). Aluno que já está no Movo: sem QR. Sem dados de saúde. Compartilha pelo menu do Android; se não der, baixa o arquivo. Sem SQL.

## 7. Riscos
- **Duplicidade com outra agenda:** mitigado com o critério de parada (ver §1).
- **Esforço de cadastro:** a primeira semana é a barreira. "Copiar semana anterior" e a recorrência são obrigatórios na fase 1.
- **Sem push:** presença pendente e lembretes dependem de o treinador abrir o app. Se a agenda virar hábito, push passa a ser prioridade (backlog).
- **Recorrência:** parece simples e não é (exclusões, edição de "esta e as próximas", horário de verão se voltar). Limitar a semanal e testar bastante.
- **Cold-start do aluno:** a agenda reduz o problema (o treinador já tem valor sem o aluno), mas o vínculo continua dependendo do aceite do convite.
- **Cinco abas:** pode apertar a navegação em telas pequenas.

## 8. Fora de escopo (ver backlog no ROADMAP)
Cobrança e pagamento, semana em lote (backlog), auto-agendamento do aluno, página pública de reserva, sincronização com Google, exportação para calendário, push, lista de presença de aula coletiva, aluno ver a agenda.
