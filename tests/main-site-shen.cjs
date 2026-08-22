// tests/main-site-shen.cjs — verify the shen site is wired into the live main site.
const { chromium } = require('/home/arch/projects/fixpointlinux.org/node_modules/playwright');

async function main() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const results = [];

  // Main site landing: components dropdown has shen-meta → (in-shell)
  await page.goto('https://fixpointlinux.org/', { waitUntil: 'networkidle' });
  await page.hover('button.toggle');
  await page.waitForTimeout(600);
  const menu = await page.locator('span.menu').innerText();
  results.push(['main dropdown has shen-meta', /shen-meta/i.test(menu)]);

  // Stack table shen-meta row has a Docs link
  const stack = await page.locator('table.stack').innerText();
  results.push(['main stack shen-meta row', /shen-meta/i.test(stack)]);

  // Click the dropdown shen-meta link -> in-shell navigates to /shen
  const shenLink = page.locator('a[data-mfe-route="/shen"]').first();
  results.push(['main has shen data-mfe-route link', (await shenLink.count()) > 0]);
  await shenLink.click();
  await page.waitForTimeout(2500);
  results.push(['in-shell nav to /shen', page.url().includes('/shen')]);
  const shenBody = await page.locator('body').innerText();
  results.push(['main mounts shen landing', shenBody.includes('A language that')]);

  results.push(['no page errors', errors.length === 0]);
  console.log('=== main-site shen wiring ===');
  let ok = true;
  for (const [name, pass] of results) { console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}`); if (!pass) ok = false; }
  if (errors.length) { console.log('  ERRORS:'); errors.forEach((e) => console.log('    ' + e)); }
  console.log(ok ? 'MAIN-SITE WIRING OK' : 'MAIN-SITE WIRING FAIL');
  await browser.close();
  process.exit(ok ? 0 : 1);
}
main().catch((e) => { console.error('FAIL', e); process.exit(1); });
