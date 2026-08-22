// tests/playground-smoke.cjs — headless-browser smoke for the shen-meta playground.
//
// Serves dist/ on a local port, loads /shen/playground/, and verifies the
// <shen-playground> custom element boots the wasm C VM in an xterm.js terminal
// and evaluates a KLambda expression.
//
// Checks:
//   1. The playground page pre-renders SSR content (no-JS) with the slot.
//   2. <shen-playground> mounts and the status flips to 'zincvm C VM booted'.
//   3. Typing "(+ 1 2)" + Enter produces "=> 3".
//   4. No page errors.
//
// Run: node tests/playground-smoke.cjs
const { chromium } = require('/home/arch/projects/fixpointlinux.org/node_modules/playwright');
const http = require('node:http');
const { readFileSync, existsSync, statSync } = require('node:fs');
const { join, extname } = require('node:path');

const ROOT = join(__dirname, '..', 'dist');
const PORT = 8791;

const MIME = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
};

function serve() {
  return http.createServer((req, res) => {
    let path = decodeURIComponent((req.url || '/').split('?')[0]);
    if (path.endsWith('/')) path += 'index.html';
    let file = join(ROOT, path);
    // Also serve dist/shen/... aliases in case anything references /shen/dist
    if (!existsSync(file) && path.startsWith('/shen/')) {
      file = join(ROOT, path.replace(/^\/shen\//, ''));
    }
    if (!existsSync(file)) {
      // try index.html fallback for SPA deep-links
      file = join(ROOT, 'index.html');
    }
    if (!existsSync(file)) { res.writeHead(404); res.end('nf'); return; }
    const type = MIME[extname(file)] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type });
    res.end(readFileSync(file));
  });
}

async function main() {
  const server = serve();
  await new Promise((r) => server.listen(PORT, r));
  const url = `http://localhost:${PORT}/shen/playground/`;

  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`console: ${m.text()}`); });

  const results = [];

  await page.goto(url, { waitUntil: 'networkidle' });
  // 1. SSR content present
  const ssrText = await page.locator('body').innerText();
  results.push(['SSR hero text', ssrText.includes('A live Shen REPL')]);
  results.push(['SSR slot', (await page.locator('[data-mfe="shen-playground"]').count()) > 0]);

  // 2. <shen-playground> boots — status text
  await page.waitForSelector('#shen-status', { timeout: 10000 });
  // wait for boot status
  await page.waitForFunction(() => {
    const s = document.getElementById('shen-status');
    return s && /booted/i.test(s.textContent);
  }, { timeout: 30000 });
  const statusText = await page.locator('#shen-status').innerText();
  results.push(['status booted', /zincvm C VM booted/i.test(statusText)]);
  results.push(['terminal mounted', (await page.locator('.xterm').count()) > 0]);

  // 3. Type an expression and evaluate
  await page.waitForSelector('.xterm textarea', { timeout: 10000 });
  await page.locator('.xterm textarea').pressSequentially('(+ 1 2)');
  await page.locator('.xterm textarea').press('Enter');
  await page.waitForTimeout(500);
  const termText = await page.locator('.xterm .xterm-rows').innerText();
  results.push(['eval (+ 1 2) => 3', termText.includes('=> 3')]);

  // Evaluate a second primitive for good measure
  await page.locator('.xterm textarea').pressSequentially('(reverse [1 2 3])');
  await page.locator('.xterm textarea').press('Enter');
  await page.waitForTimeout(500);
  const termText2 = await page.locator('.xterm .xterm-rows').innerText();
  results.push(['eval (reverse [1 2 3]) => [3 2 1]', termText2.includes('=> [3 2 1]')]);

  results.push(['no page errors', errors.length === 0]);

  console.log('=== shen playground smoke ===');
  let ok = true;
  for (const [name, pass] of results) {
    console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}`);
    if (!pass) ok = false;
  }
  if (errors.length) {
    console.log('  ERRORS:');
    for (const e of errors.slice(0, 10)) console.log('    ' + e);
  }
  console.log(ok ? 'SMOKE OK' : 'SMOKE FAIL');
  await browser.close();
  server.close();
  process.exit(ok ? 0 : 1);
}

main().catch((e) => { console.error('SMOKE FAIL:', e); process.exit(1); });
