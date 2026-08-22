// tests/live-smoke.cjs — live smoke of the deployed https://fixpointlinux.org/shen/ site.
//
// Verifies the deployed playground boots the wasm C VM in xterm.js and evaluates
// KLambda, and that the landing page SSR content + in-shell nav are live.
const { chromium } = require('/home/arch/projects/fixpointlinux.org/node_modules/playwright');

const BASE = 'https://fixpointlinux.org';

async function main() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`console: ${m.text()}`); });
  const results = [];

  // Landing SSR
  await page.goto(`${BASE}/shen/`, { waitUntil: 'networkidle' });
  const body = await page.locator('body').innerText();
  results.push(['landing SSR hero', body.includes('A language that')]);
  results.push(['landing nav shen', (await page.locator('.fixpoint-root').count()) > 0]);

  // Playground boots + evaluates
  await page.goto(`${BASE}/shen/playground/`, { waitUntil: 'networkidle' });
  await page.waitForFunction(() => {
    const s = document.getElementById('shen-status');
    return s && /booted/i.test(s.textContent);
  }, { timeout: 40000 });
  results.push(['playground status booted', true]);
  await page.waitForSelector('.xterm textarea', { timeout: 15000 });
  results.push(['xterm terminal mounted', true]);
  await page.locator('.xterm textarea').pressSequentially('(+ 1 2)');
  await page.locator('.xterm textarea').press('Enter');
  await page.waitForTimeout(700);
  const t1 = await page.locator('.xterm .xterm-rows').innerText();
  results.push(['live eval (+ 1 2) => 3', t1.includes('=> 3')]);

  // In-shell nav from landing to playground via data-mfe-route
  await page.goto(`${BASE}/shen/`, { waitUntil: 'networkidle' });
  await page.click('a[data-mfe-route="/shen/playground"]');
  await page.waitForTimeout(1500);
  results.push(['in-shell nav to playground', page.url().includes('/shen/playground')]);

  results.push(['no page errors', errors.length === 0]);

  console.log('=== live shen smoke ===');
  let ok = true;
  for (const [name, pass] of results) {
    console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}`);
    if (!pass) ok = false;
  }
  if (errors.length) { console.log('  ERRORS:'); errors.slice(0, 10).forEach((e) => console.log('    ' + e)); }
  console.log(ok ? 'LIVE SMOKE OK' : 'LIVE SMOKE FAIL');
  await browser.close();
  process.exit(ok ? 0 : 1);
}

main().catch((e) => { console.error('LIVE SMOKE FAIL:', e); process.exit(1); });
