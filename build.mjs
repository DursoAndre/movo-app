// Build do Movo: compila o app.js (JSX) com esbuild, minifica, copia as bibliotecas (React, Supabase, Lottie)
// para o próprio site e gera o index.html/sw.js finais em dist/. Roda no GitHub Actions a cada push
// (ver .github/workflows/deploy.yml). Localmente: npm install && npm run build.
//
// Teste local sem internet: VENDOR_DIR=<pasta com react.js, react-dom.js, supabase.js, lottie.js> node build.mjs
import { build } from "esbuild";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const raiz = path.dirname(new URL(import.meta.url).pathname);
const dist = path.join(raiz, "dist");
const falha = (m) => { console.error("ERRO no build: " + m); process.exit(1); };

fs.rmSync(dist, { recursive: true, force: true });
fs.mkdirSync(path.join(dist, "vendor"), { recursive: true });

// 1) app.js → um único arquivo minificado, sem Babel no navegador
const fonte = fs.readFileSync(path.join(raiz, "app.js"), "utf8");
const versao = (fonte.match(/const APP_BUILD = "([^"]+)"/) || [])[1];
if (!versao) falha("não achei APP_BUILD no app.js");
const r = await build({
  stdin: { contents: fonte, loader: "jsx", sourcefile: "app.js", resolveDir: raiz },
  bundle: false, write: false, minify: true, format: "iife", target: "es2020",
  jsx: "transform", jsxFactory: "React.createElement", jsxFragment: "React.Fragment", legalComments: "none",
});
const codigo = r.outputFiles[0].text;
const hashApp = crypto.createHash("sha256").update(codigo).digest("hex").slice(0, 10);
const nomeApp = `app.${hashApp}.js`;
fs.writeFileSync(path.join(dist, nomeApp), codigo);

// 2) bibliotecas do próprio site (em vez do CDN)
const nm = (...p) => path.join(raiz, "node_modules", ...p);
const vendorDir = process.env.VENDOR_DIR;
const origens = {
  "react.js": vendorDir ? path.join(vendorDir, "react.js") : nm("react", "umd", "react.production.min.js"),
  "react-dom.js": vendorDir ? path.join(vendorDir, "react-dom.js") : nm("react-dom", "umd", "react-dom.production.min.js"),
  "supabase.js": vendorDir ? path.join(vendorDir, "supabase.js") : nm("@supabase", "supabase-js", "dist", "umd", "supabase.js"),
  "lottie.js": vendorDir ? path.join(vendorDir, "lottie.js") : nm("lottie-web", "build", "player", "lottie_light.min.js"),
};
for (const [dest, src] of Object.entries(origens)) {
  if (!fs.existsSync(src)) falha("biblioteca não encontrada: " + src + " (rodou npm install?)");
  fs.copyFileSync(src, path.join(dist, "vendor", dest));
}

// 3) index.html: tira CDN e Babel, aponta para os arquivos locais
let html = fs.readFileSync(path.join(raiz, "index.html"), "utf8");
const troca = (de, para, rotulo) => { if (!de.test(html)) falha("trecho não encontrado no index.html: " + rotulo); html = html.replace(de, para); };
troca(/<script crossorigin src="https:\/\/cdn\.jsdelivr\.net\/npm\/react@18\/umd\/react\.production\.min\.js"[^>]*><\/script>\s*/, '<script src="vendor/react.js" onerror="showBootError(\'Falha ao carregar o React.\')"></script>\n', "React");
troca(/<script crossorigin src="https:\/\/cdn\.jsdelivr\.net\/npm\/react-dom@18\/umd\/react-dom\.production\.min\.js"[^>]*><\/script>\s*/, '<script src="vendor/react-dom.js" onerror="showBootError(\'Falha ao carregar o ReactDOM.\')"></script>\n', "ReactDOM");
troca(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@babel\/standalone\/babel\.min\.js"[^>]*><\/script>\s*/, "", "Babel");
troca(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/lottie-web@[^"]+"><\/script>/, '<script src="vendor/lottie.js"></script>', "Lottie");
troca(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\/dist\/umd\/supabase\.min\.js"[^>]*><\/script>/, '<script src="vendor/supabase.js" onerror="showBootError(\'Falha ao carregar o Supabase.\')"></script>', "Supabase");
troca(/if \(!window\.React \|\| !window\.ReactDOM \|\| !window\.Babel\) \{/, "if (!window.React || !window.ReactDOM) {", "checagem de libs");
troca(/", Babel: " \+ \(!!window\.Babel\) \+\s*/, '"" + ', "mensagem Babel");
troca(/ ou algo está bloqueando o CDN cdn\.jsdelivr\.net/, "", "texto do CDN");
troca(/<script>\s*fetch\("app\.js"[\s\S]*?<\/script>/, `<script src="${nomeApp}"></script>`, "loader do app");
if (/cdn\.jsdelivr\.net|babel/i.test(html.replace(/\/\/[^\n]*|<!--[\s\S]*?-->/g, ""))) falha("sobrou referência a CDN/Babel no index.html");
fs.writeFileSync(path.join(dist, "index.html"), html);

// 4) service worker: nome do cache = versão do app; lista de arquivos do build
let sw = fs.readFileSync(path.join(raiz, "sw.js"), "utf8");
sw = sw.replace(/const CACHE = "[^"]+";/, `const CACHE = "movo-${versao}-${hashApp}";`);
sw = sw.replace(/"\.\/app\.js",/, `"./${nomeApp}",\n  "./vendor/react.js",\n  "./vendor/react-dom.js",\n  "./vendor/supabase.js",\n  "./vendor/lottie.js",\n  "./privacidade.html",\n  "./termos.html",`);
if (!sw.includes(nomeApp)) falha("não consegui ajustar o sw.js");
fs.writeFileSync(path.join(dist, "sw.js"), sw);

// 5) arquivos estáticos
for (const f of ["manifest.json", "races.json", "runner.json", "icon-192.png", "icon-512.png", "privacidade.html", "termos.html"]) {
  fs.copyFileSync(path.join(raiz, f), path.join(dist, f));
}
const tam = (f) => (fs.statSync(path.join(dist, f)).size / 1024).toFixed(0) + " KB";
console.log(`Build ${versao} ok → ${nomeApp} ${tam(nomeApp)} (fonte: ${(fonte.length / 1024).toFixed(0)} KB)`);
