// shell/mfe/shen-playground.js — the <shen-playground> custom element.
//
// Encapsulates the zincvm C VM compiled to WebAssembly, driven by an xterm.js
// terminal. The interactive demo is NOT Elm-ified: the surrounding page (nav /
// hero / sections / footer) is rendered in Elm via the shared Fixpoint.*
// package, and only the terminal is hosted by this element.
//
// How it works:
//   1. Loads the vendored xterm.js (classic script -> global `Terminal`) and
//      the compiled emscripten module (classic script -> global
//      `createShenModule`).
//   2. Boots the wasm module and calls shen_boot() (loads the embedded
//      globals.csexp bundle + GC init, 923 closures).
//   3. Wires the terminal: on Enter, feeds the line to shen_eval_line() and
//      prints the result. The wasm entrypoint is synchronous + re-entrant, so
//      there is no blocking fgetc(stdin) and no web worker.
//
// The element uses light DOM (NOT shadow DOM) so the injected xterm.css and
// the .fixpoint-root page styles coexist simply.

const BASE = '/shen';

// Once-per-element boot guard.
const BOOTED = Symbol('booted');

// Reusable script loading (cached per URL).
const scriptCache = new Map();

function loadScript(src) {
  if (scriptCache.has(src)) {
    return scriptCache.get(src);
  }
  const promise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.async = false; // preserve ordering
    s.onload = () => { s.remove(); resolve(); };
    s.onerror = () => { s.remove(); reject(new Error(`shen-playground: failed to load ${src}`)); };
    (document.head || document.documentElement).appendChild(s);
  });
  scriptCache.set(src, promise);
  return promise;
}

// Minimal DOM builder helper.
function el(tag, attrs, children) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') node.className = v;
      else if (k === 'html') node.innerHTML = v;
      else node.setAttribute(k, v);
    }
  }
  for (const c of children || []) {
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
}

class ShenPlayground extends HTMLElement {
  connectedCallback() {
    if (this[BOOTED]) return;
    this[BOOTED] = true;
    this.buildDom();
    this.loadAll()
      .then(() => this.bootTerminal())
      .catch((err) => this.showError(err));
  }

  buildDom() {
    // Inject the xterm stylesheet once.
    if (!document.getElementById('shen-xterm-css')) {
      const link = document.createElement('link');
      link.id = 'shen-xterm-css';
      link.rel = 'stylesheet';
      link.href = `${BASE}/vendor/xterm/xterm.css`;
      document.head.appendChild(link);
    }

    this.classList.add('shen-playground');
    this.appendChild(
      el('div', { class: 'shen-playground-status', id: 'shen-status' }, [
        'booting the shen C VM…',
      ]),
    );
    this.termHost = el('div', { class: 'shen-playground-term' }, []);
    this.appendChild(this.termHost);
  }

  async loadAll() {
    // shen-wasm.js (defines global createShenModule) + xterm.js (global Terminal).
    await Promise.all([
      loadScript(`${BASE}/shen-wasm.js`),
      loadScript(`${BASE}/vendor/xterm/xterm.js`),
    ]);
  }

  async bootTerminal() {
    if (typeof createShenModule !== 'function') {
      throw new Error('createShenModule is not defined after loading shen-wasm.js');
    }
    if (typeof Terminal === 'undefined') {
      throw new Error('Terminal is not defined after loading xterm.js');
    }

    const M = await createShenModule({});
    const boot = M._shen_boot();
    if (!boot) {
      throw new Error('shen_boot() returned 0 (bundle load failed)');
    }

    this.status().textContent = `zincvm C VM booted (${boot ? '923 closures loaded' : ''})`;

    const OUTCAP = 65536;
    const outPtr = M._malloc(OUTCAP);

    const term = new Terminal({
      cursorBlink: true,
      convertEol: true,
      fontSize: 13,
      theme: {
        background: '#0b0e11',
        foreground: '#c9d1d9',
      },
    });
    term.open(this.termHost);

    const print = (msg) => {
      term.writeln(msg.replace(/\n$/, ''));
    };

    print('=== Shen meta-REPL (zincvm C VM on WebAssembly) ===');
    print('Type KLambda expressions. Examples:');
    print('  (+ 1 2)  (cons 1 2)  (hd [1 2 3])  (tl [1 2 3])');
    print('  (= [+ 1 2] [+ 1 2])  (cn "a" "b")  (reverse [1 2 3])');
    print('Ctrl-D exits.');

    let line = '';
    term.onData((data) => {
      const code = data.charCodeAt(0);
      if (code === 13) {
        // Enter: evaluate the accumulated line.
        term.write('\r\n');
        if (line.trim() === '') {
          line = '';
          term.write('meta> ');
          return;
        }
        let result;
        if (line.trim() === 'exit' || line.trim() === 'quit') {
          print('Bye.');
          term.dispose();
          return;
        }
        try {
          const linePtr = M._malloc(line.length + 1);
          M.stringToUTF8(line, linePtr, line.length + 1);
          const len = M._shen_eval_line(linePtr, outPtr, OUTCAP);
          result = len > 0 ? M.UTF8ToString(outPtr) : (len < 0 ? '<ERR>' : '');
          M._free(linePtr);
        } catch (e) {
          result = `<error: ${e.message}>`;
        }
        print(`=> ${result}`);
        line = '';
        term.write('meta> ');
      } else if (code === 127 || code === 8) {
        // Backspace.
        if (line.length > 0) {
          line = line.slice(0, -1);
          term.write('\b \b');
        }
      } else if (code === 3) {
        // Ctrl-C: clear the line.
        line = '';
        term.write('^C\r\nmeta> ');
      } else if (code === 4) {
        // Ctrl-D: exit.
        print('Bye.');
        term.dispose();
      } else {
        line += data;
        term.write(data);
      }
    });

    this.term = term;
    term.focus();
    term.write('meta> ');
  }

  status() {
    return this.querySelector('#shen-status');
  }

  showError(err) {
    if (this.status()) {
      this.status().textContent = `error: ${err.message}`;
    }
    if (this.termHost) {
      this.termHost.textContent = err.message;
    }
  }
}

if (!customElements.get('shen-playground')) {
  customElements.define('shen-playground', ShenPlayground);
}

export {};
