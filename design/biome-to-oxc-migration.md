# Biome → oxc (oxlint + oxfmt) migration plan

Staged plan for replacing Biome with oxc as the gjsify workspace lint/format toolchain,
ending with a custom `GObject.registerClass` ordering lint rule. Grounded in `refs/oxc`
(oxlint 1.66.0, oxfmt 0.50.0) and the current Biome footprint.

## oxc readiness (the decisive facts)

- **oxlint 1.66** — linter + **ESLint-compatible JS-plugin API are STABLE** (not alpha).
  `definePlugin({ meta, rules })`, `Rule.create(context)`, visitor by AST node type,
  `context.report({ message, node, fix })`, frozen `Fixer` (insert/replace/remove + range
  variants). Wired via `jsPlugins: [...]` + `"<plugin>/<rule>": "error"` in `.oxlintrc.json`.
  → The custom rule can be built today.
- **oxfmt 0.50** — formatter is **pre-1.0, breaking monthly**, Prettier-shaped options,
  has an LSP + a `migrate_biome` path. **Cannot format CSS/JSON** (biome.json.tmpl does).
  → The formatter swap is the only whole-repo reformat diff and a moving target.

**Recommendation: migrate the LINTER now (+ custom rule); defer the FORMATTER until oxfmt ≥ 1.0.**

## Current Biome footprint to migrate

Biome is *not* an npm dep — it's spawned on demand via `biome-resolve.ts` (resolves the
per-platform `@biomejs/cli-*` binary, skipping the Node launcher). No root `biome.json`;
only `biome.json.tmpl` (the `format --init` scaffold).

| Concern | File |
|---|---|
| Binary resolver + spawn + template loader | `packages/infra/cli/src/utils/biome-resolve.ts` |
| `gjsify lint` / `format` / `fix` wrappers | `packages/infra/cli/src/commands/{lint,format,fix}.ts` |
| Scaffold template (biome 2.4.13) | `packages/infra/cli/src/templates/biome.json.tmpl` |
| flatpak post-format hook | `packages/infra/cli/src/commands/flatpak/init.ts` (~L35-38, 263-280) |
| E2E suite | `tests/e2e/biome/run.mjs` + `test:e2e:biome` + root `test:e2e` chain |

Constraints: `gjsify check` is the **tsc** orchestrator, not Biome — leave it. The CLI ships
as a committed GJS bundle (`dist/cli.gjs.mjs`) — wrapper/template/resolver changes require
`gjsify workspace @gjsify/cli build:gjs-bundle` + committing the bundle. `loadBiomeTemplate()`
is matched by the static-read-inliner — keep the exact `readFileSync(new URL(...))` shape.
AGENTS.md: do NOT repurpose oxc's parser for `--globals auto` detection (stays acorn).

## Stage 1 — oxlint alongside Biome (lint-only, non-blocking)  [DO NOW]
New `utils/oxc-resolve.ts` mirroring `biome-resolve.ts` (oxlint napi `@oxlint/binding-<target>`;
reuse platform/musl detection). Add `gjsify lint --engine=oxlint|biome` (default biome). Commit
root `.oxlintrc.json` translating biome.json.tmpl's `linter` block (recommended→correctness:error;
useImportType→typescript/consistent-type-imports; noExplicitAny:warn; useNodejsImportProtocol→
unicorn/prefer-node-protocol; etc.). Additive, report-only, no CI gate. Rebuild + commit bundle.

## Stage 4 — the registerClass ordering rule (oxlint JS plugin + autofix)  [DO NOW, after S1]
Internal dir `packages/infra/oxlint-plugin-gjsify/` exporting `definePlugin({meta:{name:"gjsify"},
rules:{"register-class-order": rule}})`. `rule.create` visits `ClassBody`: find the `StaticBlock`
calling `GObject.registerClass`; collect `static` `PropertyDefinition` siblings with GObject
metadata keys (GTypeName/Properties/InternalChildren/Signals/CssName/Template/Implements/...)
that appear AFTER the block; report + autofix by hoisting each field's verbatim source above the
block (`fixer.insertTextBefore(block, text)` + `fixer.remove(field)`). Inline-rewrite to
`registerClass({...}, Foo)` is a stretch goal. JS-plugin path must spawn oxlint via its Node
launcher (not the bare binary). e2e: `tests/e2e/oxc-plugin/run.mjs`. (GNOME/gjs#704, ts-for-gir#410)

## Stage 2 — formatter swap (oxfmt)  [DEFER until oxfmt ≥ 1.0]
The high-risk half. Config from `migrate_biome` + hand-reconcile (printWidth←lineWidth:120,
indent←space/4, singleQuote, semi, trailingComma:all, arrowParens:always). Land as: (a) config
PR (no source changes), then (b) isolated mechanical whole-repo reformat PR with
`.git-blame-ignore-revs`. **CSS/JSON gap (O2): oxfmt formats JS/TS(+TOML) only** — decide
keep-Biome-for-CSS/JSON vs drop vs other tool. Budget a re-reformat per oxfmt minor until 1.0.

## Stage 3 — re-point wrappers/scaffold/e2e/editor/CI  [after S2]
`{lint,format,fix}.ts` → runOxlint/runOxfmt (`gjsify fix` = oxfmt --write + oxlint --fix).
`format --init` writes `.oxlintrc.json` + `.oxfmtrc.jsonc` (two new templates, same inliner shape).
Rename resolver. flatpak hook → oxfmt. Port `tests/e2e/biome/` → `tests/e2e/oxc/`. Add oxc VS Code
ext recommendation. Optional CI lint/format gate (O3). Remove biome.json.tmpl + biome specifics.
Update STATUS.md + AGENTS.md. Rebuild + commit bundle.

## Open questions
- **O1** plugin spawn path: JS plugins need oxlint via Node launcher (not bare binary) — OK? → default yes
- **O2** CSS/JSON: oxfmt can't format them — keep Biome for CSS/JSON, drop, or other tool? → decide at Stage 2
- **O3** add a blocking lint/format CI gate (none today)?
- **O4** keep `--engine=biome` fallback for one release vs hard-cut at Stage 3?
- **O5** oxfmt timing: 0.50 now (+ re-reformat churn) vs wait for 1.0? → **recommended: wait**
- **O6** ts-for-gir lockstep vs gjsify-first? → **recommended: gjsify first** (separate repo; its release `before:init: yarn format` would be disrupted mid-stream)
- **O7** rule home: standalone `@gjsify/oxlint-plugin-gjsify` (npm bootstrap) vs internal `packages/infra/`? → **recommended: internal first**

## Critical files
- `packages/infra/cli/src/utils/biome-resolve.ts`
- `packages/infra/cli/src/commands/{lint,format,fix}.ts`
- `packages/infra/cli/src/templates/biome.json.tmpl`
- `tests/e2e/biome/run.mjs`
- `refs/oxc/apps/oxlint/test/fixtures/fixes/plugin.ts` (JS-plugin + Fixer reference)
