# gjsify/workspace

A development workspace that bundles several related projects around **GJS** (GNOME JavaScript), **TypeScript typings for GObject Introspection**, and a handful of GNOME apps that build on top of them. Each project lives in its own repository and is pulled in here as a git submodule, so you can clone once and have everything ready to hack on side by side.

This repo is not itself a buildable project — there is no shared `package.json`, no shared toolchain. It only exists to make cross-project work easy: searching across all sources at once, keeping branches in sync, and sharing a single IDE window.

## What's inside

| Directory | What it is |
|---|---|
| [gjsify/](gjsify/) | **Node.js, Web, and DOM APIs for GJS.** Lets you write GJS apps that use `fs`, `fetch`, `Buffer`, `WebSocket`, `Canvas`, WebGL and friends — backed by native GNOME libraries (Soup, Gio, GLib, Cairo, GStreamer, WebKit, …). |
| [ts-for-gir/](ts-for-gir/) | **Generates TypeScript typings** from GObject Introspection (`.gir`) files. Produces the `@girs/*` packages that every other project in this workspace uses for type-safe GTK/Adwaita/GJS code. |
| [gnome-shell/](gnome-shell/) | A **TypeScript-friendly fork of GNOME Shell** — used as a proving ground for typings and tooling against a real-world GJS codebase. |
| [easy6502/](easy6502/) | A **6502 assembly learning environment** with three frontends (GNOME desktop, web, Android) sharing a common TypeScript core. Real-world consumer of `@girs/*` and GJS apps. |
| [eu.jumplink.Learn6502/](eu.jumplink.Learn6502/) | The **Flathub manifest** for the Learn6502 desktop app (the GNOME frontend of easy6502). |
| [pixel-rpg/map-editor/](pixel-rpg/map-editor/) | A **tile-based RPG map editor** built with Excalibur.js (browser) and GTK/Adwaita (GJS desktop) sharing a core. |
| [doc-old/](doc-old/) | Archived legacy documentation site. Kept for reference. |

## How the pieces fit together

```
      ts-for-gir
           │
           ▼
     @girs/* types  ─────────┐
           │                 │
           ▼                 ▼
        gjsify  ────────▶  easy6502, pixel-rpg, gnome-shell, …
     (Node/Web/DOM APIs      (apps that run on GJS)
      on GNOME libs)
```

`ts-for-gir` produces typings from introspection data. `gjsify` provides the runtime shims so ordinary Node.js and Web code can run under GJS. The apps use both. The upstream GJS runtime itself is not vendored at this level — it lives in `gjsify/refs/gjs` when a source reference is needed.

## Getting started

Clone everything in one go:

```bash
git clone --recurse-submodules git@github.com:gjsify/workspace.git
cd workspace
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

Each subproject has its own README and `AGENTS.md` with build instructions. Start with the one you care about:

```bash
cd gjsify && yarn install && yarn build
# or
cd ts-for-gir && yarn install && yarn start
# or
cd easy6502 && yarn install && yarn build
```

## Working with submodules

Every directory above (except `pixel-rpg/`, which is just a container) is an independent git repository. That means:

- **Commits happen inside the submodule.** `cd <project>`, branch, commit, and push there.
- **Bumping the pointer is a second step.** After pushing in a submodule, come back to the workspace root and run `git add <project> && git commit` to record the new version here.
- **Don't run `git submodule update` blindly.** It resets submodule working trees to the pinned commit and can discard local work. Check `git status` inside each submodule first.
- **Cross-project changes stay in separate commits.** One commit never spans two submodules — each repo has its own history.

## Who this is for

If you're just using one of the projects (e.g. installing `@gjsify/fetch` from npm, or trying out the Learn6502 Flatpak), **you don't need this workspace** — grab the individual project instead.

This workspace is for contributors who regularly touch multiple projects in the same session: making a breaking change in `ts-for-gir` and updating the consumers, debugging a GJS runtime issue while fixing it in `gjsify`, prototyping an app feature across `easy6502`'s shared core and the GNOME frontend, and so on.

## License

This workspace itself has no code — only submodule pointers. Each subproject is licensed under its own terms (MIT, LGPL, ISC, Apache 2.0, …); see the individual repositories.
