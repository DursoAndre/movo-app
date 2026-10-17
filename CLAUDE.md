# Movo: instruções para o Claude

1. **Leia `docs/ARQUITETURA_E_DECISOES.md` antes de qualquer tarefa.** Ele é a fonte de verdade de infraestrutura, decisões, convenções e pendências. Não pergunte ao Andre o que já está lá (ex.: o Resend já tem conta e chave).
2. **Ao terminar cada entrega, atualize esse arquivo** (decisão nova, SQL novo, função nova, pendência aberta ou resolvida, data e versão). Se o Andre tomar uma decisão na conversa, registre na seção 8.
3. Antes de afirmar que algo não existe, busque no código (`grep`) e consulte a memória.
4. Regras de entrega, SQL e testes: seção 2.1 e seção 3 do arquivo acima.
5. Respostas em pt-BR e concisas.
6. Existem **dois admins**: o "painel de métricas" (`movo-site/admin`, movoapp.com.br/admin) e a "aba Admin do app" (dentro do `app.js`). Se o Andre disser só "admin", pergunte qual. Ver seção 2.0 do arquivo acima.
