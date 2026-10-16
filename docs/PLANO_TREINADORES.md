# Plano: treinadores no Movo (visualizar, editar e enviar treinos aos alunos)

Status: **aprovado para implementação** (escopo completo com flags, revisado após parecer de PM e UX). Decisões de negócio (preço, cobrança, termos, jurídico) ficam para a conversa de negócio.

## 0. Hipótese e critérios do piloto
**Hipótese:** treinadores que hoje usam WhatsApp/planilha passam a prescrever a semana pelo Movo, e os alunos registram mais treinos do que antes.

**Sucesso (calibrar com a Dayanne):**
- Pelo menos 2 de 3 treinadores enviam a semana pelo Movo por 3 semanas seguidas, sem repetir a prescrição no WhatsApp.
- Pelo menos 70% dos convites aceitos em 7 dias.
- Pelo menos 60% dos alunos convidados registram 2 ou mais sessões por semana na semana 3.
- O treinador diz (pergunta direta) que economiza tempo.

**Falha / pivô:** treinador envia pelo Movo mas repete no WhatsApp; menos de 40% dos convites aceitos; alunos aceitam e não registram; treinador não abre o perfil (o valor estaria só no aluno).

**Linha de base:** registrar quantos alunos já treinavam no Movo antes (D30 "com vs. sem treinador" tem viés de seleção).

**Recrutamento:** Dayanne (treinadora 1) + pelo menos 1 treinador sem relação prévia. Alunos: os que ela já atende.

## 1. Problema e JTBD
- **Treinador:** "Montar, ajustar e acompanhar os treinos de vários alunos sem planilha e sem WhatsApp, e saber quem está treinando."
- **Aluno:** "Receber o treino do meu treinador no app que eu uso, registrar sem esforço e ver que ele acompanha."
- **Hoje:** o aluno monta ou importa a ficha sozinho; o treinador passa PDF/WhatsApp.

## 2. Princípios
1. O aluno é dono dos próprios dados. O treinador só vê o que o aluno autorizar; o aluno revoga quando quiser.
2. O aluno nunca perde o que já tem. O treino do treinador chega como proposta, não sobrescreve.
3. Sem app separado: mesmo Movo, com **seletor de modo no topo** ("Meu treino | Meus alunos"), visível só para quem é treinador.
4. Dados de saúde (dor, esforço) são sensíveis (LGPD): consentimento explícito, por tipo, desligado por padrão.
5. Nada muda no treino do aluno sem ele saber (sem aceite automático).

## 3. Papéis, vínculo e limites
- Usuário pode ser aluno, treinador ou os dois. Treinador = perfil em `coach_profiles` com `status` (`em_analise` → `ativo` → `suspenso`). O treinador se cadastra sozinho (login: "Sou treinador"; Configurações; menu) e o admin aprova por enquanto.
- Vínculo por **convite** (link/código) → `pendente` → `ativo` → `encerrado`/`pausado`. Qualquer lado encerra; o acesso acaba na hora.
- **Limites:** sem teto de alunos por treinador (decisão v139); 1 treinador ativo por aluno. Convite para quem já tem treinador: o app explica e pede para encerrar o atual antes.
- **Aluno menor de idade:** piloto só 18+ (declaração no aceite).
- **Política de saída:** ao encerrar, o treinador perde acesso a tudo do aluno (novo e antigo). O aluno mantém as fichas já aceitas como cópia pessoal ("Originada de {Nome}") e todo o histórico dele. O treinador mantém o que ele próprio criou (prescrições, modelos, notas) e pode exportar em CSV/JSON.

### Tabelas
- `coach_profiles(user_id, nome_exibicao, status, bio ≤160, cref, termos_versao, termos_em, motivo, ...)`. Bio/CREF só aparecem pra quem recebe ou aceita um convite (não há diretório público).
- `coach_links(id, coach_id, student_id, status, invite_code, permissions jsonb, student_label, created_at, accepted_at, ended_at)`
  - `permissions`: `{ver_treinos, ver_cargas, ver_esforco_dor (false), ver_corrida}`; o aluno liga e desliga.
- `coach_assignments(id, link_id, tipo, payload jsonb, versao, status, mensagem, created_at, seen_at, decided_at)` — status: `enviado` → `visto` → `aceito`/`recusado` → `aplicado`; `motivo_recusa` opcional.
- `coach_templates(id, coach_id, nome, payload jsonb)` — modelos do treinador.
- `coach_notes(id, link_id, author_id, date, session_ref, texto (≤500), created_at)` — comentário por sessão e resposta.
- `coach_audit(link_id, ator, acao, quando)` — só no banco, sem tela por enquanto.
- `coach_events(user_id, evento, meta, quando)` — funil desde o dia 1 (convite criado/aberto/aceito, 1ª sessão do aluno, semana enviada, treinador reabriu painel).

### Segurança
- Treinador só lê dados do aluno via RPC `security definer` que checa vínculo `ativo` + permissão. Nunca acesso direto a `app_data`.
- Permissão desligada devolve `bloqueado` (o painel mostra "Bloqueado pelo aluno", nunca zero).
- Encerrar revoga imediatamente.

## 4. Fluxos e interface

### Modo e navegação
- Seletor "Meu treino | Meus alunos" no topo, só para treinador; lembra o último modo.
- Modo treinador: cor de destaque diferente (azul), nav própria (Alunos, Modelos, Menu), faixa fixa "Editando para: {Aluno}" em qualquer tela que edita a ficha de um aluno; botão sempre "Enviar para {Aluno}", nunca "Salvar"; confirmação ao sair com mudanças não enviadas.

### Treinador
1. **Meus alunos:** busca, chips (Atenção, Sem plano na semana, Aguardando aceite, Pausados) com contadores. Ordenado por "precisa de você primeiro". Linha compacta (~64 px) com os 7 dias da semana. Alerta único no piloto: "sem treinar há N dias" (e dor 7+ quando a permissão existir).
2. **Perfil do aluno:** semana, últimas sessões, cargas, corridas (aba só aparece se há dados), notas. Dados em cache mostram "atualizado há X min".
3. **Montar e enviar:** semana como lista vertical de 7 dias; cada dia abre uma folha inferior; carga/séries/reps com teclado numérico e +/-; "copiar para outros dias"; mostra a última carga do aluno; barra fixa com resumo e **Enviar**. Rascunho automático. "Duplicar semana passada" e "Usar modelo".
4. **Importar a ficha existente** (PDF, planilha, texto do WhatsApp) com o importador atual; treinador revisa antes de enviar.
5. **Comentar** por sessão (respostas rápidas), recado opcional no envio.
6. Envio offline em fila ("Aguardando conexão"); nunca "Enviado" antes do servidor confirmar. Estados por aluno: enviado, visto, aceito, recusado, aplicado.

### Aluno
1. **Convite** abre o PWA (instalar é opcional). Tela de consentimento em frases simples, com exemplo do que o treinador verá. "Esforço e dor" desligado, com explicação.
2. **Revisão de mudanças** no Hoje: mensagem do treinador no topo, diferenças por dia em linguagem humana, aceitar/recusar por item com desfazer, "Aceitar tudo", motivo de recusa opcional. Sem ação, o treino anterior segue valendo, com selo "Nova versão".
3. Selo "Prescrito por {Nome}" nas fichas; comentário do treinador no Hoje.
4. **Meu treinador:** permissões, pausar, encerrar, exportar o que foi compartilhado.
5. Aluno sem treinador: uma linha explicando o que é e como convidar. Alternativa: compartilhar a semana por WhatsApp (texto).

## 5. Edição e sincronização
- Ficha prescrita é **cópia versionada** (`origem = {coach_id, assignment_id, versao}`); o treinador nunca grava em `app_data` do aluno.
- Editar = enviar nova versão. Aceita → o app do aluno aplica; sessões já registradas ficam ligadas à versão antiga.
- Aluno pode ajustar no dia (já existe). Mudanças permanentes na ficha prescrita voltam como sugestão.
- Anotações do aluno são preservadas. Fichas pessoais continuam intocáveis.

## 6. Flags (tudo construído, exposição gradual)
| Recurso | Estado no piloto |
|---|---|
| Convite, consentimento, revisão, envio, importação, modelos, duplicar, comentário | ligado |
| Esforço/dor (alertas e dados) | **desligado** até OK jurídico; opt-in do aluno separado |
| Envio em lote / turmas | desligado |
| Plano de corrida pelo treinador | ligado só se o aluno corre |
| Aceite automático | **não será construído** |
| Mensagens gerais, anexos, diretório público de treinadores | **não serão construídos** |
| Tela de auditoria | adiada (dados já gravados) |
| Rascunho por IA | adiado |

## 7. Jurídico e negócio (checklist, sem decidir aqui)
Papéis controlador/operador; consentimento granular e provável (versão do texto, data, revogação) para dado de saúde (art. 11); efeitos da revogação e prazo de retenção; menores; responsabilidade pela prescrição e CREF/auto-declaração; transferência internacional (Supabase, IA); DPO/RIPD; o Movo não intermedeia pagamento nem oferece aluno de um treinador a outro; monetização só depois do checkpoint.

## 8. Métricas
Treinadores ativos (enviaram nos últimos 14 dias); alunos por treinador; convites aceitos em 7 dias; tempo do convite ao 1º treino registrado; sessões/semana do treinador no modo "Meus alunos"; % de alunos que ligam esforço/dor por conta própria; minutos para migrar 3 alunos (meta: menos de 30).

## 9. Ordem de entrega
1. Banco: tabelas, RLS, RPCs, limites, eventos.
2. Aluno: convite, consentimento, Meu treinador, revisão de mudanças.
3. Treinador: seletor, lista, perfil, montar/enviar, modelos, duplicar, importar, comentários.
4. Checkpoint após 3 semanas de uso real: aplicar os critérios da seção 0, e só então ligar dor/esforço e decidir Fase 3 (push, turmas, painel web).


## 7. Revisão v139 (treinador autônomo)

Decisões do Andre: sem limite de alunos; o aluno também convida o treinador; perfil visível só pra quem recebe/aceita convite; admin aprova por enquanto; suspensão congela os vínculos e avisa o aluno.

- **Modo treinador:** abas Alunos · Atividade · Modelos · Perfil. Nenhum item do menu do aluno aparece. Topo: "Modo treinador" fixo + seletor compacto (ponto quando há novidade).
- **Perfil (editável):** foto (mesma do perfil pessoal), nome, bio, CREF opcional, prévia "como o aluno me vê", contagens, conta/ajuda/feedback/sair.
- **Atividade:** treinou (com dor só se o aluno permitiu), aceitou/recusou/viu a semana (com motivo), comentários, aluno novo, convites expirando/expirados. Badge nas novidades desde a última visita.
- **Modelos:** criar, editar, renomear, duplicar, aplicar em aluno (abre o rascunho dele), apagar com confirmação.
- **Autocadastro:** `coach_apply` (nome, bio, CREF opcional, termos v1: 18+, responsabilidade, uso só do autorizado) → `em_analise`. Em análise: pode montar modelos e editar perfil; convites só depois de aprovado.
- **Convite reverso:** o aluno gera `?prof=CODE` (permissões + 18+) em Meu treinador; o treinador abre, se cadastra se precisar e aceita (`coach_student_invite_*`). Fica registrado em `coach_audit` (origem `convite_do_aluno`).
- **Suspensão:** `admin_coach_decide(user, 'suspenso', motivo)` congela vínculos (`congelado`, guarda o status anterior) e o aluno vê aviso em Meu treinador; reativar restaura (se o aluno não tiver outro vínculo).
- **Admin:** fila "em análise" com Aprovar/Recusar, Suspender (motivo), Reativar; liberar direto por e-mail continua.
- **LGPD:** exportação inclui convites feitos ao treinador e consentimentos do aluno e do treinador.
- SQL: `supabase/sql/coach_setup_v2.sql` (idempotente; rodar depois de `coach_setup.sql`).
