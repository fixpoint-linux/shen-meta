// shell/shell.js — @mfe/framework thin-shell entry for the shen-meta MFE site.
//
// Boots the shen docs app with 6 routes:
//   '/'                → template 'fixpoint'       (cross-nav home, main site)
//   '/shen'            → template 'shen-landing'
//   '/shen/architecture' → template 'shen-architecture'
//   '/shen/build'      → template 'shen-build'
//   '/shen/primitives' → template 'shen-primitives'
//   '/shen/playground' → template 'shen-playground'
//
// Matching the main site means a data-mfe-route like '/shen' or '/' resolves
// the same way on either page, so cross-site MFE nav links agree.
//
// The pages ship statically pre-rendered (see scripts/ssg.mjs): the #app root
// carries an `ssr` attribute, so createApp rehydrates the existing DOM in
// place instead of wiping it and re-fetching the template on first paint.
//
// Rehydrate only when the current pathname (trailing-slash-stripped) matches
// a pre-rendered shen page (i.e. starts with /shen — ALL five pages are
// pre-rendered, including the playground, whose chrome is Elm while the
// <shen-playground> custom element boots client-side).

import { createApp } from '@mfe/framework';

const app = await createApp({
  root: document.getElementById('app'),
  routes: [
    { path: '/', template: 'fixpoint', name: 'home' },
    { path: '/shen', template: 'shen-landing', name: 'shen-landing' },
    { path: '/shen/architecture', template: 'shen-architecture', name: 'shen-architecture' },
    { path: '/shen/build', template: 'shen-build', name: 'shen-build' },
    { path: '/shen/primitives', template: 'shen-primitives', name: 'shen-primitives' },
    { path: '/shen/playground', template: 'shen-playground', name: 'shen-playground' },
  ],
  basePath: '/',
  // shen's templates are served from /shen/shell/templates
  // (the main site owns /shell/templates). Pin the baseURL here so both route
  // templates resolve under this site's shell regardless of the deep-link subpath.
  baseURL: '/shen/shell/templates',
  // The SSG output pre-renders all five content pages (incl. the playground's
  // Elm chrome). Rehydrate whenever the current pathname is a /shen route.
  ssr: (() => {
    const path = (window.location.pathname.replace(/\/+$/, '') || '/');
    return path.startsWith('/shen');
  })(),
});

// Expose the app handle so the shell/host can inspect or drive it later.
window.__shenApp = app;
