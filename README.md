# Movo

Todos os seus treinos e atividades, numa só evolução. Agenda semanal (fichas de academia + atividades como vôlei/CrossFit/Hyrox), checklist de exercícios com peso/reps, status feito/pulei, e evolução de frequência e carga. PWA com login (magic link) e sincronização em nuvem via Supabase — os dados ficam salvos por conta, acessíveis em qualquer aparelho.

## Como publicar no GitHub Pages

1. Crie um repositório novo no GitHub (ex: `treino-app`).
2. Suba todos os arquivos desta pasta pra raiz do repositório (`index.html`, `app.js`, `manifest.json`, `sw.js`, `icon-192.png`, `icon-512.png`).
3. No repositório, vá em **Settings → Pages**.
4. Em "Source", selecione a branch `main` (ou `master`) e a pasta `/ (root)`.
5. Salve. Em alguns minutos o app estará em `https://SEU-USUARIO.github.io/treino-app/`.
6. Abra esse link no celular e use "Adicionar à tela inicial" (Android/Chrome) ou "Adicionar à Tela de Início" (iOS/Safari) pra instalar como app.

## Atualizando o app depois

Se pedir pro Claude alterações no app, é só substituir o `app.js` (e outros arquivos que mudarem) no repositório — o GitHub Pages atualiza sozinho. Os dados salvos no seu celular não são afetados por isso, só o código.

## Importando/editando fichas de treino

Na aba **Treinos**, use "Importar treino (JSON)" — peça pro Claude gerar o JSON de uma ficha nova nesse formato e cole ali.

## Estrutura de dados (localStorage)

- `treino-app:treinos` — fichas de academia (blocos/exercícios)
- `treino-app:atividades` — atividades externas (vôlei, CrossFit, Hyrox, etc.)
- `treino-app:schedule` — agenda semanal (dia → itens)
- `treino-app:sessions` — registros por data (pesos, reps, status, comentários)

## Licença

Código proprietário, todos os direitos reservados. Ver [LICENSE](LICENSE). Visível publicamente só para o app poder rodar no navegador; cópia, redistribuição e uso do nome/identidade visual dependem de autorização.

## Build e publicação (a partir da v109)

O código-fonte continua sendo o `app.js` (JSX) e o `index.html` na raiz. A cada push na `main`, o GitHub Actions
(`.github/workflows/deploy.yml`) roda `npm run build` (`build.mjs`): compila e minifica o app com esbuild, copia
React, Supabase e Lottie para `dist/vendor/` e publica a pasta `dist/` no GitHub Pages. Para isso, em
**Settings → Pages → Build and deployment**, a fonte (*Source*) precisa ser **GitHub Actions**.

Rodar localmente: `npm install && npm run build` e servir a pasta `dist/` (ex.: `python3 -m http.server --directory dist`).
