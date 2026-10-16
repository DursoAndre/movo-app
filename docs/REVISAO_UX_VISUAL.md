# Revisão UX / Visual / Produto / Acessibilidade — Movo (v121)

Quatro especialistas (UX, UI, PM/gamificação, acessibilidade) revisaram as 23 telas principais (360px) e o código. Itens de negócio (gratuito x pago, domínio, jurídico, beta) ficam fora, para conversa posterior.

## Princípios que guiam as mudanças
1. Um toque até a ação principal do dia (treinar). 2. Sem culpa: avisos em tom positivo, vermelho só para erro. 3. Cada tela tem UM botão primário. 4. Ícones e cores consistentes. 5. Alegria nos momentos certos: concluir treino, bater recorde, passar um amigo na pista.

## Achados prioritários (consenso entre especialistas)

### Alta prioridade
1. **Hoje — dia sem treino é beco sem saída** (UX, UI, PM). Mostrar o próximo treino como cartão herói com "Adiantar pra hoje"; "Registrar outra atividade" secundário.
2. **Hoje — treino do dia como herói** (já planejado): cartão grande com nome, duração, nº de exercícios e botão "Iniciar".
3. **Hoje — aviso "Sua semana mudou / Faltou…" soa como cobrança** (UX, PM, UI). Reescrever: "Sua semana mudou. Quer reorganizar?" [Reorganizar] [Deixar assim], em âmbar, não vermelho; um único botão cheio na tela.
4. **Conclusão de treino sem celebração** (PM). Hoje só aparece o formulário de esforço. Novo: tela de conclusão com duração, séries, volume, recordes, sequência, posição no desafio, botão compartilhar; esforço vira passo opcional.
5. **Convite pelo WhatsApp** (PM, UX): botão "Chamar no WhatsApp" na lista de Desafios, ao criar desafio e no Ranking vazio (hoje manda ir em Configurações → Amigos).
6. **Configurações sem hierarquia** (UX, UI): textos explicativos sem caixa; "Excluir minha conta" em zona de perigo, vermelha; sincronizar vira linha de status.
7. **Acessibilidade estrutural** (A11y): foco visível global, `prefers-reduced-motion` global, `role=dialog`+Esc nos modais, `aria-label` nos botões de ícone (✕ ‹ › ⋯ +), alvos de toque de 44px, contraste de bordas/trilhas.

### Média prioridade
8. **Escala tipográfica**: 20 tamanhos → 6 tokens (11/12/14/16/20/28); texto secundário mínimo 12–14px; muted um pouco mais claro.
9. **Raios**: 10 valores → 3 (8, 14, pílula).
10. **Emojis → ícones SVG** únicos (traço 1.5px) em onboarding, sheets, menu, desafios; emoji só no conteúdo compartilhável.
11. **Cores de estado**: verde-sucesso distinto do lime, âmbar para atenção, vermelho só para erro/destrutivo.
12. **Evolução**: abas em chips rolantes; Carga traduzida ("Últimos 7 dias" / "Média de 28 dias"), medidor com progresso até liberar; barras mais visíveis; estados vazios com CTA; `<select>` nativo → seletor no tema.
13. **Desafios**: "Como funciona" recolhido; "Confirmar treino junto" vira banner compacto no topo quando pendente; regra de pontos explícita (+5 pts); cartões mostram posição e dias restantes; **a pista é mantida e ganha detalhes** (avatares maiores, ultrapassagem animada).
14. **Treinos (semana)**: dia de hoje destacado, "+" secundário, "⋯" com área de 44px, toque no item abre a ficha.
15. **Criar desafio**: nome e data com padrões inteligentes.
16. **Retenção**: resumo semanal ("sua semana em 3 números"), progresso exclusivo ("+X% no supino em 6 semanas", só com 4+ semanas de dados), sequência semanal, selos.

### Depois (infra)
17. **Lembretes push** — exigem service worker com handler de push, chaves VAPID, tabela de inscrições, função agendada. Preparo o que for código; o que depende de você está listado na entrega.

## Cortes / ocultações propostos — NADA será feito sem seu OK
(nenhum remove a pista de corrida nem o menu lateral completo)
- Hoje: link "Já usa o Strava?" sai da tela principal (continua no menu, onboarding e Configurações).
- Evolução → Ranking: reduzir os dois grupos de filtros a um seletor.
- Evolução → Carga: esconder Aguda/Crônica e razão enquanto houver <4 semanas de dados.
- Treinos: dias de descanso viram uma linha compacta.
- Ajustar semana: remover blocos vermelhos duplicados do resumo.
- Menu: unir "Nova ficha / Montar com IA / Fichas prontas" num item (sugestão do UX; contraria seu gosto pelo menu completo, então só se você pedir).
- Evolução: esconder abas Notas/Ranking até haver dados (sugestão da UI).

## Ordem de entrega
- **Onda A (v122):** Hoje herói + dia livre + aviso positivo; tela de conclusão com recorde e sequência; convite WhatsApp.
- **Onda B (v123):** tokens (fontes, raios, cores de estado), ícones SVG, hierarquia de botões, Configurações.
- **Onda C (v124):** acessibilidade (modal, foco, aria, motion), Evolução e gráficos.
- **Onda D (v125):** Desafios (como funciona, banner, pontos), resumo semanal, progresso exclusivo, selos.
- **Onda E:** push (depende de passos seus).
