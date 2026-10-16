# Próximos passos (planos para executar 1 a 1)

Ordem sugerida: **A (feito) → D → B → C**. A é pequeno e visível; D não depende de IA nem de banco; B reaproveita a infraestrutura de IA que já existe; C é o maior e depende de decisões de produto.

Infra já pronta e reaproveitável: edge function `gerar-plano` (stream + heartbeat, chave só no servidor, `max_tokens`, timeout), cota mensal por pessoa (`plan_generations` + `reserve_/refund_plan_generation`), validação do JSON no cliente com prévia antes de salvar, `exercise_suggestions` (nomes que não existem no catálogo), importador de fichas por JSON (`handleImport`, `EXEMPLO_JSON`).

---

## A. Tela de geração do plano (animação + contagem regressiva) — FEITO (v81)

**Objetivo:** a espera de 1–2 min parece curta e "viva", sem prometer um tempo que não controlamos.

**Design**
- Corredor em SVG com ciclo de corrida em CSS (pernas/braços alternando) sobre um chão que desliza (parallax simples). Sem libs; respeita `prefers-reduced-motion` (vira só a barra).
- **Contagem regressiva** de uma estimativa (padrão 2:00; depois calibrada pela mediana das últimas gerações da própria pessoa, guardada no aparelho). Mostrada como anel/barra que esvazia + "≈ 1:25".
- **Termina antes → muda na hora**: o fim real da geração sempre manda; o timer é só estimativa. Rápido "Plano pronto ✓" (~600 ms) e abre a prévia.
- **Passou da estimativa (zerou e não terminou):** não fica "00:00" travado. Troca para "Quase lá…" com barra indeterminada e um contador discreto de tempo extra.
- Barra de progresso não linear (sobe rápido até ~70%, depois devagar até 95%, nunca 100% antes de terminar).
- Mensagens rotativas por fase, ligadas ao que a IA realmente faz ("Analisando seu ponto de partida…", "Montando as semanas de base…", "Ajustando longões e polimento…").
- Manter o aviso ao sair (já existe) e o diagnóstico em caso de erro.

**Futuro (separado):** geração em segundo plano que entrega o plano mesmo se a pessoa sair da tela.

**Testes:** estado "gerando" mostra anel + mensagem; resolve antes do fim → vai direto à prévia; passa da estimativa → "Quase lá"; reduced-motion sem animação; regressão dos `verify_plano_ia`.
**Esforço:** pequeno (1 sessão).

---

## B. Treino de academia 100% personalizado com IA (quarto caminho)

**Contexto:** hoje há 3 caminhos (montar à mão, catálogo/ficha pronta, importar JSON colando de uma IA externa). O novo: o app chama a IA direto e entrega uma ficha pronta para revisar.

**Anti-abuso (decisão central: NÃO é chat)**
- Entrada **estruturada**: objetivo, dias/semana, duração por treino, local/equipamentos, nível, lesões/restrições, preferências (máx. 300 caracteres de texto livre, filtrado), divisão desejada (ou "você escolhe").
- System prompt fechado: só responde com o JSON da ficha; fora de escopo → `{"erro":"fora_do_escopo"}`. Saída máxima limitada, prompt máximo limitado.
- **Cota mensal própria** (sugestão: 5/mês) — generalizar a tabela de uso com uma coluna `tipo` ('plano_corrida' | 'treino_academia' | 'historico'), mantendo reserva atômica e estorno em falha.
- Resultado **não é conversa**: só vira ficha depois da prévia e do "Salvar".

**Qualidade**
- A IA recebe a lista de exercícios do catálogo (ids/nomes) e é instruída a usar só esses; o que fugir vai para a prévia marcado e para `exercise_suggestions`.
- Opcional (fase 2): usar o histórico real da pessoa (cargas recentes, frequência, dores) para dosar séries/cargas e progressão.
- Regras de método explícitas no prompt (volume por grupo/semana, ordem composto→isolador, descanso, progressão), como fizemos no plano de corrida.

**Implementação**
1. SQL: generalizar cota (`ai_generations`/coluna `tipo`) + RPCs com `p_tipo`; manter compatibilidade com `plan_generations`.
2. Edge function `gerar-treinos` (cópia do padrão de `gerar-plano`, schema de saída = `EXEMPLO_JSON`).
3. Cliente: nova tela "Criar com IA" (formulário curto → geração com a tela do item A → prévia usando o mesmo normalizador do `handleImport` → salvar).
4. Eventos (`treino_ia_pedido/gerado`), admin: uso por tipo no painel.

**Testes:** formulário valida; harness simula resposta (ok/erro/limite/fora de escopo); exercícios fora do catálogo sinalizados; regressão das fichas.
**Decisões abertas:** limite mensal; gerar 1 ficha ou a semana inteira (A/B/C…); usar histórico já na v1?
**Esforço:** médio (2–3 sessões).

---

## C. Importar histórico de treinos de um arquivo (interpretado por IA) — FEITO (v88)

**Entregue:** menu → Importar histórico. Aceita texto/CSV/TSV/MD/JSON, Excel (SheetJS carregado sob demanda), PDF, fotos (redimensionadas no aparelho) e zip/txt do WhatsApp. Partes de até 9 mil caracteres, 3 em paralelo, via função `importar-historico` (job em `ai_jobs`); cota `historico` 3/mês (`ai_quota_kinds.sql`, admin sem limite). Revisão obrigatória, não sobrescreve dias preenchidos, fichas criadas ou casadas por nome, exercícios casados com os seus/catálogo, tudo marcado com `imp` e com "Desfazer". Falhas totais devolvem a cota. Pendente (futuro): retomar importação após recarregar a página; reconhecer corridas do Strava duplicadas.

**Resposta curta: dá, sim.** O ROADMAP já previa o caminho "IA interpreta o arquivo e devolve JSON". Agora temos a API para fazer isso sem copiar e colar.

**Arquivos aceitos**
- CSV/TXT/Markdown: lidos direto no aparelho.
- XLSX: convertido para texto/CSV no aparelho (biblioteca carregada sob demanda).
- PDF e foto/print: enviados à IA (a API lê PDF e imagem nativamente).
- Limite de tamanho; histórico grande é **dividido em blocos** (por período/linhas), processado em sequência com barra de progresso e resultado mesclado.

**Saída da IA (esquema)**
- `fichas[]`: treinos recorrentes que a pessoa já fez (nome + exercícios com séries/reps), para criar fichas novas.
- `sessoes[]`: `data`, ficha/nome do treino, `exercicios[]` com `sets[{peso, reps}]`, e opcionais duração/RPE/dor/observações.
- `corridas/atividades[]` (opcional) e `avisos[]` (ambiguidades: unidade lb×kg, datas sem ano etc.).

**Casamento e segurança dos dados**
- Nomes de exercício casados com o catálogo por regra (normalização + fuzzy) e, se preciso, pela IA; não casados → revisão manual na prévia (casar, criar exercício próprio ou ignorar) e sugestão ao catálogo.
- **Prévia obrigatória:** período, nº de sessões/fichas, conflitos com dias que já têm registro (padrão: **não sobrescrever**; opções mesclar/pular), unidades detectadas.
- Cada importação recebe um id e marca as sessões criadas → **"Desfazer importação"**.
- O arquivo não é guardado: passa pela função, que repassa à IA, e é descartado. Aviso claro de privacidade antes de enviar.

**Implementação (fases)**
1. Cliente: seletor de arquivo, extração local (CSV/XLSX), tela de prévia e mapeamento, gravação em `sessions[data].log["treino:<id>"][exercício].sets` + criação de fichas, desfazer.
2. Edge function `importar-historico` (blocos, stream, cota própria `tipo='historico'`, limites de tamanho/páginas).
3. PDF/imagem (visão) e blocos grandes.
4. Admin/eventos e ajuste de custo (estimativa de tokens por arquivo).

**Testes:** fixtures de CSV (Strong/Hevy), planilha caseira, texto livre; duplicados; unidades; desfazer; muito grande (blocos).
**Decisões abertas:** cota (sugestão 2–3 importações/mês); permitir criar fichas automaticamente ou só histórico; importar corridas também.
**Riscos:** custo por arquivo grande; números alucinados (mitigado por prévia e avisos); formatos exóticos.
**Esforço:** grande (3–5 sessões).

---

## D. Biblioteca de treinos de corrida avulsos ("montar treino") — FEITO (v82)

**Problema:** hoje, ao adicionar uma corrida como atividade, não existe o "treino montado" (aquecimento, tiros, ritmo, desaquecimento) que só aparece dentro de um plano gerado pela IA.

**Proposta (a sua ideia, com um ajuste):** na criação de uma corrida avulsa, um botão **"Montar treino"**: a pessoa escolhe **distância** e **tipo de treino**, o app **monta as etapas na hora** (sem IA, sem cota, funciona offline), mostra a prévia e **salva em "Meus treinos de corrida"**, de onde pode ser colocado na agenda em qualquer dia, quantas vezes quiser.

**Por que sem IA:** os formatos clássicos são conhecidos e dá para gerá-los por regras (como o app já faz no plano). É instantâneo, grátis e previsível. A IA entra depois só como "personalizar" (opcional, com cota).

**Tipos de treino (com nomes que corredor reconhece)**
- Rodagem leve e Regenerativo
- Longão (constante ou progressivo)
- Ritmo / Tempo run (blocos contínuos no ritmo de limiar)
- Intervalado: tiros curtos (200/400 m), médios (800/1000 m), Yasso 800
- Fartlek (variações livres por tempo)
- Progressivo (cada trecho mais rápido)
- Subidas (opcional)

**Como monta:** parâmetros = distância total, tipo, nível (iniciante/intermediário/avançado), pace de referência (opcional, o app tenta usar o histórico/Strava). O gerador calcula aquecimento (~10–15%), bloco principal (repetições, distância/tempo, pausa) e desaquecimento, ajustando para fechar a distância pedida. Saída no **mesmo formato de `etapas` do plano** (já renderizado por `PlanoEtapas`, com paces e gráfico).

**Agenda:** o treino salvo vira item que pode ser agendado em um dia (como um treino de academia); no dia aparece no mesmo cartão do plano (título, km, esforço, etapas, Fiz/Pulei). Se houver corrida do Strava no dia, sugerir vincular.

**Fases**
1. Gerador por regras (`planoGerarTreinoCorrida(tipo, km, nivel, pace)`) + testes unitários dos formatos (somam a distância, ritmos coerentes).
2. UI: fluxo "Montar treino" na criação de corrida avulsa + prévia.
3. Biblioteca "Meus treinos de corrida" + agendar em qualquer dia.
4. (Opcional) "Personalizar com IA" usando a cota; reaproveitar os modelos para guiar a IA do plano.

**Decisões abertas:** os treinos salvos ficam só no aparelho ou vão para a nuvem junto das fichas; permitir editar etapas à mão; unidade das etapas (m, km, min).
**Esforço:** médio (2 sessões).


---

## Formato curto do plano de corrida com IA (v93)
Medido: ~15,3 mil tokens de saída por plano (~US$ 0,16, quase 2 min). Agora a IA devolve só `modelo` (rodagem, tiros400, tempo...), km, duração, esforço, pace e `nota`; o app monta título e etapas com `planoGerarTreinoCorrida` (`planoExpandirCompacto`). O prompt de copiar e colar continua no formato completo. Sem mudança na edge function.

## B — Montar treinos de academia com IA (v94)
- Novo card "✨ Montar com IA" em Treinos → "+ Novo treino" (o antigo "Gerar com IA" virou "Colar JSON").
- Questionário em 4 passos: objetivo e nível; treinos por semana, duração e divisão; local e grupos de atenção; meta e limitações (texto curto, opcional).
- Função `gerar-treinos` (prompt fechado montado no servidor, valores validados, texto livre tratado como dado). Cota: 5 por mês, tipo `treino` (admin sem limite); reserva devolvida se falhar. Sem SQL novo (usa `ai_jobs` e `ai_quota_kinds`).
- A IA devolve JSON compacto; o app casa os nomes com o catálogo (`histCasarExercicio`), agrupa em blocos por grupo muscular, mostra prévia e abre no construtor (`Revisar e salvar`) para ajustar e salvar várias fichas de uma vez.
- Ideias futuras: usar as cargas do histórico para sugerir progressão; agendar as fichas nos dias da semana ao salvar.

## Ajustar minha semana com IA (v96)
- **Entrada:** menu Musculação → "Ajustar minha semana" e card "🔧 Sua semana mudou" na Hoje (só aparece quando há desvio: treino faltado, atividade fora do planejado puxada, 3 dias seguidos de carga alta, dor registrada; dá para dispensar). Chip "↻ Semana ajustada" depois de aplicar.
- **Código mede, IA recomenda:** `semanaFatos` calcula a semana (domingo a sábado, igual à tira da Hoje): planejado x feito, carga (minutos x esforço), extras, grupos musculares e sinais. `semanaPayload` manda um resumo compacto (sem comentários nem dados pessoais) para a função `ajustar-semana`.
- **Validação:** `semanaValidarProposta` aceita reduzir séries, tirar exercício, encurtar/suavizar corrida (mín. 40% da distância), pular ou mover para um dia restante. **Reposição (v97):** treinos perdidos da semana (P1…) podem ser refeitos em outro dia, e dá para diluir o grupo perdido incluindo até 3 exercícios do catálogo por treino (5 na semana) e +1 série em até 3 exercícios por treino (8 séries na semana, máx. 6). Corrida nunca aumenta. "Não vou treinar hoje" marca o treino de hoje para mover ou pular. Atividades fora do app só entram na conta da carga.
- **Relatório:** veredito, motivos, contadores Fica/Muda/Sai e um cartão por treino restante com cada mudança marcável (steppers de séries e km, "manter este dia como está"). Nada é salvo até "Aplicar".
- **Aplicar/desfazer:** ajuste guardado por data (`sessions[d].semana`, `planos[].sessoes[].ajuste` com o original). Não altera a ficha-base; o treino aparece com "↻ ajustado". Um ajuste por semana; "Desfazer" restaura tudo.
- Cota: 6 por mês (tipo `ajuste_semana`; admin sem limite), reserva devolvida se falhar. Sem SQL novo.
- Ideias futuras: mostrar os ajustes na Evolução, aprender com o que a pessoa aceita/recusa, ajustar também quando uma atividade é adicionada no meio da semana, notificar.

## Feedback dos usuários (v98)
Menu → Conta → "💬 Enviar feedback" (tipo + mensagem + "pode responder"). Grava em `user_feedback` (SQL: `supabase/sql/user_feedback_setup.sql`, limite 10/dia) e aparece no Painel admin ("Feedback dos usuários", marcar lido, responder por mailto). E-mail opcional: edge function `notificar-feedback` (secret `RESEND_API_KEY`; opcionais `FEEDBACK_TO`, `FEEDBACK_FROM`).
