# Contributing to shen-meta

Thanks for being here. This project is a meta-circular Shen runtime — Shen compiling itself to native bytecode on a Zig VM. It's experimental, opinionated, and very much in progress.

## Getting started

```sh
git clone https://github.com/jmars/shen-meta.git
cd shen-meta
make bundle  # builds globals.csexp via vendored shen-scheme (needs bundle for tests)
make         # build shensh + zincdec (Zig port)
make test    # zig build test -Doptimize=Debug (gc + vm suites)
```

## How to help

### Good first issues

- Port a Shen KLambda primitive to the Zig VM (check the missing list in the README)
- Write a test for an edge case (error handling, type mismatches, tail calls)
- Improve error messages in the ZINC compiler or Zig VM
- Document the bytecode format beyond the quick summary
- Add benchmark scaffolding (execution time, memory usage)

### Areas to dive deeper

- **Self-hosting** — reduce the dependency on shen-scheme
- **Serialization** — the csexp bundle format needs a specification
- **VM optimization** — the Zig VM is simple by design, there's room for speed

### Not sure where to start?

Open an issue with what you're interested in and your experience level. No bad ideas.

## Guidelines

- CI runs on every PR. `make test` is the gate. If you see a green badge on the README, your PR passes.
- Keep it small. Prefer a focused PR over a sprawling one.
- Tests pass before you open the PR. `make test` is the gate.
- Match the existing style. The Zig code is flat with clear names; the Shen code uses the project naming conventions.
- The architecture README is the source of truth for design decisions. If something doesn't match, flag it.

## Code of conduct

Be generous. Assume good faith. This project exists because someone was curious about what happens when you push an old idea (meta-circular evaluation) into an old formalism (sequent calculus) with a new tool (LLMs). That's the spirit.

## License

MIT. See LICENSE.
