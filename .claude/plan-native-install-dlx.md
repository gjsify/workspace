# Plan — Node-independent `gjsify install` & `gjsify dlx`

**Goal:** Make `gjsify install` and `gjsify dlx` runnable without Node.js installed. Today both spawn `npm install` (see [packages/infra/cli/src/utils/install-backend.ts:40](../gjsify/packages/infra/cli/src/utils/install-backend.ts#L40)). The end state: a GJS-native npm registry client + tarball extractor + dep resolver, gated by `GJSIFY_INSTALL_BACKEND=native|npm` (the seam already exists, [install-backend.ts:29](../gjsify/packages/infra/cli/src/utils/install-backend.ts#L29)).

Secondary goal: confirm `gjsify dlx` correctly wires native prebuilds (gwebgl, terminal-native, webrtc-native) for showcases that depend on them.

## Current state (after PR #66 merge, 2026-05-05)

- `gjsify dlx <spec>` exists, caches at `$XDG_CACHE_HOME/gjsify/dlx/<sha256>/`, runs the bundle via `runGjsBundle()` ([dlx.ts:101](../gjsify/packages/infra/cli/src/commands/dlx.ts#L101)).
- `runGjsBundle()` already detects native prebuilds via two paths ([run-gjs.ts:1-30](../gjsify/packages/infra/cli/src/utils/run-gjs.ts#L1-L30)):
  1. Filesystem walkup from CWD (finds packages in user project)
  2. `require.resolve` from bundle location (finds packages alongside the bundle)
  Walkup logic: [detect-native-packages.ts:107-130](../gjsify/packages/infra/cli/src/utils/detect-native-packages.ts#L107-L130).
- Install backend is `npm install` via spawn — fails if `npm` is not on PATH.
- Showcases known to depend on `@gjsify/webgl` (gwebgl prebuild): `excalibur-jelly-jumper`, `three-geometry-teapot`, `three-postprocessing-pixel`.

## Open questions to verify before Phase 1

These probably already work but are unverified — fix gaps before building anything new:

- [ ] **dlx + prebuild end-to-end**: `gjsify dlx @gjsify/example-dom-three-geometry-teapot` actually finds gwebgl in the dlx cache and sets `LD_LIBRARY_PATH`/`GI_TYPELIB_PATH`. The walkup in `detectNativePackages` starts at the bundle path which sits in `~/.cache/gjsify/dlx/<sha>/live/node_modules/<pkg>/dist/` — it should find the sibling `node_modules/@gjsify/webgl/prebuilds/` two levels up. Add an e2e test asserting both env vars are set when running a showcase that uses gwebgl.
- [ ] **Showcase publishing status**: confirm `@gjsify/example-dom-*` packages are actually published to npm (Phase D made `gjsify showcase` delegate to `gjsify dlx <pkg>` — this only works once they're on the registry).

If either fails, fix in a small precursor PR before starting Phase 1.

## Architecture

Three new packages under `packages/node/` (cross-platform — must run on Node + GJS):

| Package | Responsibility | Key references |
|---|---|---|
| `@gjsify/npm-registry` | Fetch package metadata + tarballs from `registry.npmjs.org` (or override). Handle 404, rate limits, ETag. Auth tokens via `~/.npmrc`. | [refs/npm-cli/workspaces/libnpmfetch](../gjsify/refs/npm-cli/workspaces/libnpmfetch), [refs/bun/src/install/npm.zig](../gjsify/refs/bun/src/install/npm.zig) |
| `@gjsify/tar` | Streaming `.tar.gz` extractor. Reads with `@gjsify/zlib` (gzip) + tar parser. Honor symlinks, file modes, long names (PAX). | [refs/node-tar](https://github.com/isaacs/node-tar) (consider as `refs/`), [refs/bun/src/install/extract_tarball.zig](../gjsify/refs/bun/src/install/extract_tarball.zig) |
| `@gjsify/semver` | Semver range parser + matcher. Subset is enough — no `prerelease` exotica needed for the registry-resolution path. | [refs/npm-cli](../gjsify/refs/npm-cli) `node-semver` |

Plus one CLI utility:

| Module | Responsibility |
|---|---|
| `packages/infra/cli/src/utils/install-backend-native.ts` | Resolver + downloader + writer. Reads metadata via `@gjsify/npm-registry`, walks the dep tree using `@gjsify/semver`, downloads tarballs in parallel, extracts via `@gjsify/tar`, writes to a flat `node_modules/` layout (npm-compatible — same shape as today's `npm install --prefix`). |

**Layout choice — flat `node_modules/`, not CAS.** pnpm-style content-addressable stores save disk but require symlinking, which collides with how `runGjsBundle` walks `node_modules`. Keep the on-disk layout identical to npm so existing detection logic and Node-runtime fallback both work without branching.

## Phase plan

### Phase 1 — Foundation packages (Node + GJS)

Build and test the three new packages standalone, with `@gjsify/unit` covering both runtimes. No CLI integration yet.

**1.1 — `@gjsify/semver`** (smallest, no I/O — start here)
- Port `node-semver`'s `Range`, `SemVer`, `satisfies`, `maxSatisfying` (just these — skip the rest).
- Reference: [refs/npm-cli/node_modules/semver](../gjsify/refs/npm-cli/node_modules/semver) (will need to add as ref submodule).
- Acceptance: 100% of `node-semver` tests for the ported subset pass on both runtimes.

**1.2 — `@gjsify/npm-registry`**
- HTTP via `@gjsify/fetch` (Soup on GJS, native fetch on Node) — already cross-platform.
- API surface: `fetchPackument(name, opts?)`, `fetchTarball(url, opts?)` returning `Uint8Array`, `resolveAuth(registryUrl, npmrcPath?)`.
- Honor `~/.npmrc` (`registry=`, `_authToken=`, scoped registries `@scope:registry=`).
- Acceptance: fetch `lodash` packument, resolve `lodash@^4`, download + verify integrity (sha512 from packument).

**1.3 — `@gjsify/tar`**
- Streaming reader: `extractTarball(buffer | ReadableStream, destDir)`. Strip leading `package/` (npm convention).
- Use `@gjsify/zlib` for gunzip (already present, GStreamer-free path via `Gio.ZlibCompressor`).
- Tar format: ustar minimum, PAX extended headers for long paths. Skip GNU exotica until something needs it.
- Acceptance: extract a real `.tgz` from npm, file modes preserved (especially `.bin/` symlinks).

### Phase 2 — Native install backend (CLI)

**2.1 — `install-backend-native.ts`**
- Implements `installPackages(opts: InstallOptions)` matching the existing signature.
- Resolver: BFS over deps, version pinning per (package, parent) triple to handle conflicting requirements (npm v7+ semantics — duplicates allowed when peer ranges disagree).
- Skip `devDependencies` of installed packages (npm default for non-root).
- Skip `peerDependencies` initially — emit a warning only.
- Skip lifecycle scripts (`preinstall`, `install`, `postinstall`) by default. Add `--allow-scripts` later (Phase 4 — security review needed).
- Parallel tarball downloads (cap concurrency at 8, configurable via `GJSIFY_INSTALL_CONCURRENCY`).
- Write to flat `node_modules/<pkg>/` (or `node_modules/@scope/<pkg>/`) — identical shape to npm.
- Bin links: write `node_modules/.bin/<bin>` symlinks per `package.json#bin`.

**2.2 — Wire up the seam**
- `install-backend.ts` already dispatches on `GJSIFY_INSTALL_BACKEND`. Replace the `throw` for `'native'` with an import + delegate.
- Default stays `npm` for now — opt-in via env var until Phase 3.

**2.3 — Tests**
- Unit: resolver picks the right version under conflicts.
- Integration (`tests/integration/`): install `picocolors` (zero-dep), `chalk` (a few deps), `axios` (transitive http stack). Both backends must produce equivalent `node_modules/` (compare directory hashes).
- E2E: extend `tests/e2e/cli-only/run.mjs` with `GJSIFY_INSTALL_BACKEND=native gjsify install <pkg>`.

### Phase 3 — Default to native, keep npm as fallback

- Flip the default: `GJSIFY_INSTALL_BACKEND` defaults to `native`. `npm` remains as a fallback (`gjsify install --backend=npm` flag).
- `gjsify dlx` now installs without spawning `npm` — works on a system without Node.
- Self-host check: a fresh GJS-only environment (no `node`, no `npm` on PATH) can run `gjsify install lodash` and `gjsify dlx @gjsify/example-dom-canvas2d-fireworks`.
- CLI documentation: update `website/src/content/docs/cli-reference.md` (note: native backend is default, no Node required).
- Update `STATUS.md`: native install backend → `Working`, list known limitations.

### Phase 4 — Lockfile + dlx-specific polish

**4.1 — Lockfile**
- Write `gjsify-lock.json` on `gjsify install`. Pin: name, resolved-url, integrity (sha512), version, dependencies map.
- Format: subset of npm `package-lock.json` v3 — same field names, restricted shape. Lets users hand-edit and read with familiar tools.
- `gjsify install` honors lockfile when present (no resolver pass — direct downloads from pinned URLs).
- `gjsify install --no-lockfile` to skip.

**4.2 — dlx improvements**
- Cache key already covers spec + version. Add lockfile-aware variant: `gjsify dlx --frozen <spec>` reads a project-local `gjsify-lock.json` for transitive pinning (reproducible script execution).
- `gjsify dlx --reinstall <spec>` bypasses cache (already documented as `--cache-max-age=0`, but `--reinstall` is more discoverable).
- Document the `gjsify run`-equivalence explicitly: dlx already uses `runGjsBundle()` so prebuild env vars are wired identically. Add a sentence to the dlx `--help` text and CLI docs.

**4.3 — Lifecycle scripts (optional, security-gated)**
- Default: skip scripts (status quo).
- Opt-in: `gjsify install --allow-scripts <pkg-allowlist>` runs `preinstall|install|postinstall` for explicitly listed packages only. Modeled on pnpm's `onlyBuiltDependencies` allowlist (defense against arbitrary code execution from transitive deps).
- Reference: [refs/pnpm](../gjsify/refs/pnpm) `pnpm/lifecycle/`.

## Out of scope (explicitly deferred)

- **Workspace protocol** (`workspace:^`): only meaningful inside a monorepo. `gjsify install` targets standalone GJS apps. Defer until a real consumer asks.
- **Git deps** (`git+https://...`): rarely used by GJS apps. Add when a showcase needs it.
- **Tarball deps from local paths**: already supported by `dlx <local-path>` mode; not a blocker for `install`.
- **Audit / fund / outdated subcommands**: pure ergonomics, not blocking Node-independence.
- **Yarn / pnpm-style lockfile import**: `gjsify-lock.json` is the source of truth.

## Acceptance criteria

The plan is complete when **all** of the following hold:

1. `which node && which npm` both fail (e.g., container with `gjs` only) AND `gjsify install picocolors && gjsify dlx @gjsify/example-dom-canvas2d-fireworks` both succeed end-to-end.
2. `gjsify dlx @gjsify/example-dom-three-geometry-teapot` runs the WebGL showcase, with prebuilds (`@gjsify/webgl/prebuilds/linux-*/`) detected and `LD_LIBRARY_PATH` + `GI_TYPELIB_PATH` set automatically. Confirmed by inspecting the `$ ` line printed by `runGjsBundle`.
3. CI's `tests/e2e/cli-only/` covers both backends. The `npm` backend remains for users who want it but is no longer required.
4. STATUS.md "Open TODOs" entry for native install backend is moved to `### Completed`.

## Risks

- **Tarball extraction edge cases**: long paths, hardlinks, sparse files. Mitigation: strict subset (ustar + PAX names), surface unsupported entries as errors rather than silent skip.
- **Registry quirks**: deprecated packages, malformed packuments. Mitigation: schema validate at the boundary, fail loudly with the offending field.
- **Self-hosting**: `gjsify install` must work to install gjsify itself in a bootstrap scenario. We avoid the chicken-and-egg by keeping the `npm` backend as a fallback indefinitely (it just isn't the default).
- **Performance**: native backend will likely be slower than npm initially (no cold-cache parallelism tuning). Acceptable while correctness lands; optimize once tests are green.

## Follow-ups from ts-for-gir Phase B (2026-05-05)

Surfaced while landing ts-for-gir [PR #378](https://github.com/gjsify/ts-for-gir/pull/378) on top of gjsify v0.3.5. Not blockers for `gjsify install`, but they all sit in the same area (gjsify bundling external GJS apps that depend on `@gjsify/*` polyfills) and should land before or alongside Phase 1 to keep the integration story honest.

### F1 — `gjsify build` two-hop PnP relay is silently broken

**Bug:** `packages/infra/cli/src/actions/build.ts` (the v0.3.5 fix for the npm-installed-`@gjsify/cli` relay path) does:

```ts
pnpApi = (await import("pnpapi"));
// later:
pnpApi.resolveRequest(args.path, relayIssuer);  // ← TypeError, swallowed
```

`await import("pnpapi")` on the ESM side returns the module namespace `{default, "module.exports"}`, not the CJS exports object — so `pnpApi.resolveRequest` is `undefined` and every relay call throws `TypeError`, which is then silently swallowed by the surrounding `catch {}`. Net effect: the relay is a no-op. Verified locally:

```
keys: [ 'default', 'module.exports' ]
has resolveRequest: undefined
default.resolveRequest: function ✓
```

**Fix (one line):** unwrap the namespace in `getPnpPlugin()`:

```ts
const mod = await import("pnpapi");
pnpApi = (mod as any).default ?? mod;
```

**Why this matters for downstream consumers:** without the relay, an npm-installed `@gjsify/cli` cannot resolve `@gjsify/fs` / `@gjsify/path` / etc. through `@gjsify/node-polyfills`. Consumers like ts-for-gir are forced to keep all 18+ granular `@gjsify/*` packages as direct devDeps + `nodeLinker: node-modules` + `packageExtensions` workarounds — exactly the ugliness Phase B was meant to delete. ts-for-gir PR #378 ships v0.3.5 with that ugliness still in place; cleanup is gated on a v0.3.6 release that fixes this.

**Acceptance:** `tests/integration/ts-for-gir/` (or a new integration test) bundles ts-for-gir with `@gjsify/cli` installed from npm (not workspace) using only `@gjsify/cli` + `@gjsify/empty` as devDeps under PnP linker — bundle succeeds, all `node:*` imports relay through `@gjsify/node-polyfills`. Workspace-internal usage already works because PnP sees workspace deps directly; this regression only surfaces for npm-installed consumers.

### F2 — Add an integration test for npm-installed `@gjsify/cli` under PnP

The Phase A v0.3.5 relay was validated via `tests/integration/ts-for-gir/` — but that suite uses `"@gjsify/cli": "workspace:^"`, which never exercises the relay (workspace deps are visible to PnP without it). F1 went undetected because no test in gjsify pretends to be an external consumer with an npm-installed `@gjsify/cli`.

**Action:** add `tests/integration/external-consumer/` (or extend ts-for-gir suite with an alternate variant) that:

- declares `@gjsify/cli` from a tarball (`yarn pack`-ed locally) instead of `workspace:^`,
- uses `nodeLinker: pnp`,
- declares zero granular `@gjsify/*` devDeps,
- runs `gjsify build` on a source file that imports `node:fs`, `node:path`, `node:child_process`,
- asserts the bundle resolves all three through the polyfills.

This test would have caught F1 immediately. It also locks in the contract for `gjsify install` Phase 2 (native backend output must satisfy the same external-consumer scenario).

### F3 — Cross-runtime `dynamic-import-of-CJS` audit

F1 is one instance of a class of bug. Anywhere `gjsify` does `await import("<cjs-module>")` and then accesses named exports, the namespace-vs-default trap applies — including likely candidates such as `pnpapi`, `module`, `node:module`, and the alias plugin's `await import("@gjsify/<pkg>")` paths.

**Action:** grep `packages/infra/` for `await import\(` and audit each call. Prefer the unwrap pattern `(m as any).default ?? m` for known-CJS targets. Add a lint rule (custom Biome rule or an ESLint check via `eslint-plugin-import/no-default-export-mismatch`-style) so future regressions surface in CI.

### F4 — Bundle the `pnpapi` access into `@gjsify/resolve-npm`

Today `@gjsify/cli`'s `actions/build.ts` reaches into `pnpapi` directly. That coupling is invisible to anyone reading the resolve plugin. Move the relay logic into a small helper inside `@gjsify/resolve-npm` (or a new `@gjsify/pnp-relay` package) so both the build path and any future consumer (e.g. `gjsify install --link-mode=pnp`) share one tested implementation.

This is housekeeping, not urgency — but it pairs naturally with the F1 fix.

### F5 — gjsify rewriter onLoad runs *after* `@yarnpkg/esbuild-plugin-pnp`'s, breaking PnP-linker bundles

Surfaced while landing the ts-for-gir Phase B cleanup commit (`@gjsify/cli@^0.3.6` + drop granular polyfill devDeps). With `nodeLinker: node-modules`, ts-for-gir's GJS bundle works cleanly. With `nodeLinker: pnp`, the bundle ships and runs but crashes on the very first import of TypeScript (typedoc → typescript → CJS module load):

```
Gjs-CRITICAL: JS ERROR: ReferenceError: __filename is not defined
  isFileSystemCaseSensitive@bundle:45142
  getNodeSystem@bundle:44932
  pnp:/.../typescript-patch-bfb0cdd3b9/.../typescript.js@bundle:248201
```

**Why:** esbuild calls registered `onLoad` callbacks in plugin-registration order, stopping at the first non-null result. In `actions/build.ts`:

```ts
plugins: [...pnpPlugins, gjsifyPlugin(...)]   // pnp registered FIRST
```

`@yarnpkg/esbuild-plugin-pnp`'s setup registers `build.onLoad({ filter }, defaultOnLoad)` which reads any matching path and returns its contents — **wins for everything in the `pnp` namespace**. The gjsify rewriter's `build.onLoad({ filter, namespace: "pnp" }, ...)` (added in v0.3.5 to inject `__filename`/`__dirname` for CJS code under PnP) is registered later and never fires, because the pnp plugin already returned.

Under `nodeLinker: node-modules` the issue doesn't surface — files live in the `file` namespace and the gjsify rewriter is the only plugin claiming them.

**Fix options:**

1. **Reorder onLoad registration.** Inside `gjsifyPlugin.setup`, register the rewriter's pnp-namespace onLoad *before* the pnp plugin's onLoad. Tricky from the plugin-API side because both setups run in plugin order; the practical fix is to call `build.onLoad` for `namespace: "pnp"` from `actions/build.ts` *before* awaiting the pnp plugin's setup, or to invert the plugin order to `[gjsifyPlugin, ...pnpPlugins]` (risky — gjsify's onResolve assumes pnp resolved first).
2. **Compose with the pnp plugin's reader.** Wrap `getPnpPlugin()` to return a plugin whose onLoad reads via the official path *and* runs the gjsify rewriter on the contents before returning. Single source of truth, no ordering games.
3. **Read explicitly in the rewriter.** Drop `args.path.includes("node_modules")` early-out and always `readFile` first; on failure, fall through to the next plugin. Already what v0.3.5 attempts — the fall-through doesn't help because the pnp plugin runs *before* the rewriter, so the rewriter never gets a chance.

Option (2) is the cleanest fit. It keeps the pnp plugin opaque (you don't reorder anything in the global plugin pipeline) and ensures the rewriter sees every CJS file, regardless of namespace.

**Acceptance:** in the existing `tests/e2e/cli-only-pnp/` suite, add a test that bundles a CJS module which references `__filename` (e.g. `import "typescript"` — typescript's `getNodeSystem` calls `isFileSystemCaseSensitive(swapCase(__filename))`) and asserts the bundle runs under `gjs` without `ReferenceError: __filename is not defined`. Reverting the F5 fix must reproduce the ts-for-gir-style crash.

**Why this matters for ts-for-gir:** the Phase B cleanup commit on PR #378 had to keep `nodeLinker: node-modules`. With F5 fixed, ts-for-gir can finally restore PnP linker (the original PR target) — the cleanup will be a one-line `.yarnrc.yml` change.

## Suggested execution order

1. Verify the open questions above with a tiny precursor PR (e2e test for dlx + prebuild). 1–2 days.
2. Phase 1 packages, in order semver → tar → npm-registry. ~1 week each, can overlap once interfaces are agreed.
3. Phase 2 native backend, behind env var. Heavy testing pass. ~2 weeks.
4. Phase 3 flip default, gather feedback. ~1 week.
5. Phase 4 lockfile + dlx polish. ~1 week.

Total: ~6–7 weeks of focused work. Phases 1.1–1.3 can be parallelized across contributors (they share no code).
