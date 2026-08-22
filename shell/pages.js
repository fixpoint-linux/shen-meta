// shell/pages.js — canonical page definitions for the shen-meta MFE site.
//
// Single source of truth for all routes, templates, slots, and output paths.
// Imported by both shell/shell.js (browser ESM) and scripts/ssg.mjs (Node ESM).
//
// CANONICAL ROUTE TABLE (5 shen pages):
//   '/shen'              → template 'shen-landing'
//   '/shen/architecture' → template 'shen-architecture'
//   '/shen/build'        → template 'shen-build'
//   '/shen/primitives'   → template 'shen-primitives'
//   '/shen/playground'   → template 'shen-playground'
//
// SLOT NAME == TEMPLATE NAME for all shen pages.
// The landing page's `dir` is '' so its output is dist/index.html.
// All other content pages have dir == slug, output to dist/<slug>/index.html.
// The playground IS Elm-rendered (its hero/sections) with the interactive
// wasm VM + xterm.js terminal hosted by the <shen-playground> custom element,
// so it is type 'content' like the other pages (it IS pre-rendered).
// The cross-nav home route '/' → 'fixpoint' is handled separately (main site owns
// /shell/templates/fixpoint.html and the importmap key 'fixpoint-landing').

export const PAGES = [
  {
    slug: 'shen',
    path: '/shen',
    slot: 'shen-landing',
    template: 'shen-landing',
    dir: '',
    title: 'shen-meta — self-hosted Shen on a native C VM',
    type: 'content',
  },
  {
    slug: 'architecture',
    path: '/shen/architecture',
    slot: 'shen-architecture',
    template: 'shen-architecture',
    dir: 'architecture',
    title: 'Architecture — shen-meta',
    type: 'content',
  },
  {
    slug: 'build',
    path: '/shen/build',
    slot: 'shen-build',
    template: 'shen-build',
    dir: 'build',
    title: 'Build — shen-meta',
    type: 'content',
  },
  {
    slug: 'primitives',
    path: '/shen/primitives',
    slot: 'shen-primitives',
    template: 'shen-primitives',
    dir: 'primitives',
    title: 'Primitives — shen-meta',
    type: 'content',
  },
  {
    slug: 'playground',
    path: '/shen/playground',
    slot: 'shen-playground',
    template: 'shen-playground',
    dir: 'playground',
    title: 'Playground — shen-meta',
    type: 'content',
  },
];

// All content pages (Elm-rendered) — all of shen's pages, since the
// playground is Elm-rendered chrome + a custom element for the terminal.
export const CONTENT_PAGES = PAGES.filter((p) => p.type === 'content');

// Just the shen pages (all of them)
export const SHEN_PAGES = PAGES;
