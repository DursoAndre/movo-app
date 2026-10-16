# Plano do Movo: validar o negócio e gerir os prêmios dos desafios

Atualizado em 16/10/2026, a partir da conversa com o Lucas Basques e do estado real do app. Não é parecer jurídico nem contábil: onde aparece "confirmar com especialista", a decisão depende de gente habilitada.

**Resumo.** O conselho do Lucas é: primeiro entender o usuário (problem-solution fit), depois testar canais e venda (product-channel fit). Na maior parte já temos a base, mas faltam a virada de domínio, o painel de retenção e uso por funcionalidade, e qualquer prova de que alguém paga. Os prêmios dos desafios são a feature com mais potencial e também o maior risco: começam como controle de acertos entre amigos (sem tocar em dinheiro) e só viram custódia depois de CNPJ, parceiro licenciado e parecer jurídico.

## 1. O que temos, o que temos mais ou menos e o que não temos

| Tema (da conversa) | Situação | O que existe hoje | O que falta |
|---|---|---|---|
| Entender o usuário a fundo | Mais ou menos | Eventos de uso (`app_events`, 46 pontos no app), aberturas por versão, feedback dentro do app, painel admin | Entrevistas com usuários; retenção D1/D7/D30; ver quem desistiu e onde |
| Taxa de uso de cada funcionalidade | Mais ou menos | Os eventos existem | Painel "% de usuários ativos na semana que usou cada funcionalidade"; diferença entre o que dizem e o que fazem |
| Domínio e hospedagem profissionais | Mais ou menos | Landing em movoapp.com.br no ar, HTTPS ligado em 16/10; banner de mudança pronto e desligado (`dominio_novo.ativo = false`) | Migrar o app para app.movoapp.com.br e virar a chave (lista na seção 3) |
| Convite apontando para o endereço novo | Não temos | Convite usa o endereço antigo (github.io) | Convite pelo domínio estável (seção 3) |
| Pacote de funcionalidades em plano pago | Mais ou menos | Planos, teste de 30 dias, limites e flags prontos e dormentes | Checkout (Asaas), CNPJ ou MEI, termos de cobrança e reembolso, nota fiscal |
| Testar canais de captação | Mais ou menos | Contadores anônimos na landing com origem (`lp_events`), convites por link | Ligar origem, cadastro e ativação; testar 2 ou 3 canais com meta |
| Validação real de venda | Não temos | 40 usuários, nenhum pagante | Teste de disposição a pagar (lista de espera ou pré-venda) |
| Cobrar sem CNPJ | Não sabemos | Resposta do Claudio foi confusa | Pergunta objetiva ao contador (seção 5) |
| Gerir os prêmios dos desafios | Mais ou menos | Aposta semanal e final como texto livre ("paga um café"); pontos, semanas, ganhador e quem paga já calculados | Valores em reais, saldo de quem deve a quem, confirmação de pagamento |
| Segurar o dinheiro até o fim e liberar | Não temos | Nada | Parceiro licenciado, CNPJ, termos, parecer jurídico (seção 4) |
| Rendimento do dinheiro em custódia (CDI) | Não temos | Nada | Só depende do parceiro e da regra; não contar como receita no plano |

## 2. Ordem de execução

**Agora (próximas 2 a 3 semanas): fundação e aprendizado**
1. Migrar o app para app.movoapp.com.br e fazer o convite apontar para um endereço estável (seção 3). É o atrito que o Lucas chamou de "bruto": quanto mais gente entra no endereço antigo, mais gente precisa reinstalar.
2. Painel de uso e retenção: uso por funcionalidade na semana, retenção D1/D7/D30, funil de primeiro treino.
3. Conversar com 5 a 8 usuários (inclua quem você não conhece) e 3 a 5 personais.
4. Mandar as perguntas da seção 5 ao contador e a um advogado.

**Depois: product-channel fit e venda**
5. Teste de venda antes do checkout: lista de espera ou pré-venda do plano pago, com meta de conversão definida de antemão.
6. Canais: escolher 2 ou 3 (convite de amigo, personal que traz alunos, Instagram) e medir cadastro até primeiro treino.
7. Checkout Asaas quando houver CNPJ ou MEI e sinal de que alguém paga.

**Prêmios dos desafios** (seção 4)
8. Fase P1, controle de acertos sem custódia: depois da migração de domínio.
9. Fase P2, custódia: só depois de passar nos critérios da seção 4.

## 3. Migração do app e convites

Checklist da virada: CNAME `app` apontando para `dursoandre.github.io`, arquivo CNAME no repositório do app, URLs de Auth no Supabase, callback do Strava, links de convite, manifest, página de privacidade, `{{APP}}` em `_src/build.py` da landing, e então `dominio_novo.ativo = true`.

**Feito na v174:** os links de convite (desafio, treinador e aluno→treinador) já saem como `movoapp.com.br/convite/?...`; a página `convite/` da landing leva ao app. Ao migrar o app, trocar `APP` em `_src/build.py` da landing e rodar o build.

Convites: a ideia do Lucas funciona. Em vez de o app gerar link para o endereço do app, gerar link `movoapp.com.br/convite?desafio=CODE` (ou `?treinador=CODE`). A landing, que já é nosso domínio estável, redireciona para o endereço do app que estiver valendo. Assim, trocar o app de endereço no futuro não quebra convite. Limite: quem ainda tem a versão antiga continua gerando o link antigo. Mitigação provável: o GitHub Pages redireciona o endereço antigo do projeto para o domínio personalizado depois da migração. Testar se o redirecionamento preserva o `?desafio=CODE` antes de virar a chave.

## 4. Prêmios dos desafios: acerto de contas e custódia do dinheiro

**Este trabalho lida com dinheiro dos outros. Princípios que não se negociam:**
- O Movo nunca guarda dinheiro de terceiros em conta própria ou pessoal. Quem segura e libera é um parceiro já autorizado pelo Banco Central.
- Só entra dinheiro de verdade depois do parecer jurídico e do CNPJ.
- O cálculo de quem ganha e quanto é feito no servidor, imutável e auditável, nunca no aparelho (hoje os pontos são calculados no cliente; isso muda antes de qualquer valor real).
- Cada passo começa pequeno: valores baixos, poucos amigos, liberação aprovada manualmente por você.
- Um interruptor geral (como o de IA) pára novas entradas e liberações em um clique.
- Só maiores de 18 anos.

### Fase P1: controle de acertos (sem o Movo tocar em dinheiro)
Objetivo: o grupo já combina "quem perde paga". O app só faz a conta e mostra quem deve o quê, e o pagamento acontece por fora (Pix entre eles).
- **Valores estruturados** na criação do desafio: valor por semana e/ou valor final em reais, modo (perdedor paga ao ganhador, ou pote com cada um entrando com o mesmo valor) e regra de divisão do pote. Travam quando o desafio começa, como as regras de hoje.
- **Fechamento no servidor:** pontos e resultado da semana calculados por função no banco, que grava lançamentos (semana, de quem, para quem, valor). Lançamentos nunca são editados; correção é um lançamento novo que compensa.
- **Tela "Acertos":** saldo de cada pessoa desde o começo, quem deve a quem (com as dívidas simplificadas), valor final de premiação e quem paga nos desafios com prêmio.
- **Confirmação em duas pontas:** o pagador marca "paguei" e o recebedor confirma "recebi". Lembrete para quem está devendo.
- **Contestação:** prazo curto (por exemplo 48 horas) para contestar um check-in; regra clara de quem decide; check-in com Strava vale mais que manual.
- **Saída do desafio:** quem sai paga o que já deve até ali.
- **Termo na tela:** o Movo organiza a conta e não intermedeia pagamento.
- **Critério para sair da P1:** ver desafios com valor em reais acontecendo e pessoas pedindo para o app segurar o dinheiro.

### Fase P2: custódia (segurar e liberar)
Pré-requisitos, todos antes de escrever a primeira linha:
1. CNPJ ou MEI e contador.
2. Parecer jurídico sobre os itens da seção 5.
3. Parceiro licenciado com retenção e liberação (subconta ou conta de pagamento com split), contrato aprovado.
4. Termos de uso e política de reembolso específicos, aceite explícito de quem entra com dinheiro.

Fluxo proposto:
- Entrada por Pix, uma cobrança individual por participante; dinheiro fica retido no parceiro, nunca no Movo.
- Estados: aguardando pagamento, pago e retido, liberado, devolvido, em disputa.
- Ao fim, o servidor calcula, você aprova a liberação (no piloto), o parceiro paga os ganhadores e desconta a taxa do Movo. Tudo vira lançamento no registro.

Casos que o desenho precisa cobrir antes de lançar:
- Desafio não começa (mínimo de participantes não atingido): devolução integral.
- Participante não paga até a data: fica fora; o valor do pote é recalculado antes de começar.
- Empate; vencedor sem Pix cadastrado (prazo e destino do dinheiro); desafio cancelado; erro de cálculo; disputa aberta congela a liberação.
- Estorno de cartão: aceitar só Pix na fase inicial.
- Webhooks do parceiro assinados e idempotentes; reconciliação diária entre o que o parceiro diz e o nosso registro; alerta se não bater.
- Chaves do parceiro só em funções de borda, nunca no app; acesso a dados de pagamento restrito por RLS; trilha de auditoria completa.
- Teto de valor por pessoa e por desafio no começo; piloto fechado com amigos e valores baixos.

Receita possível: taxa sobre o pote (take rate). Rendimento do dinheiro em custódia (a "caixinha 100% CDI" da conversa) só existe se o parceiro oferecer e a regra permitir; de quem é o rendimento precisa estar nos termos. **Não entra em projeção de receita até haver resposta jurídica.**

### Critérios para avançar da P1 para a P2
- Desafios com valor em reais ativos e recorrentes na P1.
- Parecer jurídico favorável por escrito.
- CNPJ ou MEI e parceiro contratado.
- Plano de piloto e interruptor geral prontos.

## 5. Perguntas para contador e advogado (confirmar com especialista)
1. Posso começar a cobrar o plano pago como pessoa física ou preciso de CNPJ ou MEI antes? Qual o limite e como emitir nota?
2. Segurar dinheiro de participantes e liberar no fim caracteriza atividade regulada (instituição ou arranjo de pagamento)? Usando um parceiro licenciado com retenção e split, o Movo fica fora do perímetro?
3. Prêmio pago com dinheiro dos próprios participantes, definido por desempenho, é jogo, aposta ou concurso? Que autorização ou formato evita o enquadramento (por exemplo, depósito de compromisso devolvido a quem cumpre a meta, em vez de pote entre participantes)?
4. Tributação: a taxa do Movo, o prêmio recebido pelo participante e o rendimento, se houver.
5. Obrigações de identificação do cliente e prevenção à lavagem de dinheiro: o parceiro cobre?
6. Termos, política de reembolso, direito de arrependimento e responsabilidade em caso de erro ou fraude.
7. De quem é o rendimento do dinheiro retido e como informar isso.

## 6. Decisões que dependem de você
- Prioridade: virar o domínio antes de qualquer outra coisa (recomendado).
- Modelo do prêmio na P1: perdedor paga ao ganhador, pote, ou os dois.
- Se aceita começar a P1 sem o parecer (ela não move dinheiro, só calcula e mostra), deixando a P2 para depois.
- Quem faz as perguntas da seção 5 e até quando.
