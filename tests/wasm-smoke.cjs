// tests/wasm-smoke.cjs — Node verification of the committed shen wasm module.
//
// Proves the committed docs/shen-wasm.js + docs/shen-wasm.wasm (built by
// scripts/build-wasm.sh) boots the zincvm C VM and evaluates KLambda through
// the synchronous shen_eval_line() entrypoint — no blocking stdin, no worker.
//
// Run: node tests/wasm-smoke.cjs
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { createRequire } = require('node:module');

// The committed module is ESM-shaped (MODULARIZE). Load it via a temp copy so
// require() treats it as CommonJS (matching the verified build's harness).
const os = require('node:os');
const { writeFileSync } = require('node:fs');
const tmpdir = os.tmpdir();
const js = readFileSync(join(__dirname, '..', 'docs', 'shen-wasm.js'), 'utf8');
const wasm = readFileSync(join(__dirname, '..', 'docs', 'shen-wasm.wasm'));
const dir = `${tmpdir}/shen-wasm-smoke-${process.pid}`;
const fs = require('node:fs');
fs.mkdirSync(dir, { recursive: true });
writeFileSync(`${dir}/shen-wasm.js`, js);
writeFileSync(`${dir}/shen-wasm.wasm`, wasm);
const req = createRequire(`${dir}/`);
const createShenModule = req('./shen-wasm.js');

const OUTCAP = 65536;

async function main() {
  const M = await createShenModule();
  const boot = M._shen_boot();
  console.log('BOOT =', boot);
  if (!boot) throw new Error('shen_boot returned 0');

  const outPtr = M._malloc(OUTCAP);
  const evalLine = (line) => {
    const linePtr = M._malloc(line.length + 1);
    M.stringToUTF8(line, linePtr, line.length + 1);
    const len = M._shen_eval_line(linePtr, outPtr, OUTCAP);
    const out = len > 0 ? M.UTF8ToString(outPtr) : (len < 0 ? '<ERR>' : '');
    M._free(linePtr);
    return out;
  };

  const cases = [
    ['(+ 1 2)', '3'],
    ['(cons 1 2)', '[1 . 2]'],
    ['(= [+ 1 2] [+ 1 2])', 'true'],
    ['(< 1 2)', 'true'],
    ['(hd [1 2 3])', '1'],
    ['(tl [1 2 3])', '[2 3]'],
    ['(cn "a" "b")', '"ab"'],
    ['(reverse [1 2 3])', '[3 2 1]'],
  ];

  let bad = 0;
  for (const [input, expected] of cases) {
    const out = evalLine(input);
    const pass = out === expected;
    if (!pass) bad++;
    console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${input}  ->  ${out}${pass ? '' : ` (expected ${expected})`}`);
  }

  // GC stress: 2000 evals, results must stay correct.
  let stressBad = 0;
  for (let i = 0; i < 2000; i++) {
    if (evalLine('(cons 1 2)') !== '[1 . 2]') stressBad++;
  }
  console.log(`  STRESS 2000 evals, mismatches = ${stressBad}`);
  if (stressBad > 0) bad += stressBad;

  M._free(outPtr);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(bad === 0 ? 'WASM SMOKE OK' : `WASM SMOKE FAIL (${bad})`);
  process.exit(bad === 0 ? 0 : 1);
}

main().catch((e) => { console.error('WASM SMOKE FAIL:', e); process.exit(1); });
