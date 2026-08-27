---
name: Primitive port
about: Port a Shen KLambda primitive to the Zig VM
title: 'Port primitive: '
labels: good first issue, enhancement
assignees: ''

---

**Primitive name**

**Current status**

**Reference implementation**
Link to the shen-scheme equivalent or the Shen OS source.

**Acceptance criteria**
- [ ] Primitive is implemented in `zig/src/vm/prims.zig` (or `execplan.zig` for process prims)
- [ ] Safe wrapper is added in `shen/primitives.shen`
- [ ] A test case in the Zig VM test suite
- [ ] `make test` passes
