# devcontainer — build & pin

Builds and publishes the devcontainer image consumed by `devcontainer.json`.
Run [`commands.sh`](./commands.sh) from the repo root after setting `GIT_PAT`.

---

## Two-phase install model

The devcontainer installs tooling in two independent phases. Understanding
this is required before changing any version pin.

| Phase | Owner | Installs | When it runs |
|---|---|---|---|
| **1 — image build** | `.devcontainer/Dockerfile` | Base image, apt packages, COPY'd files | `docker build` (or devcontainer `build` block) |
| **2 — container start** | `bootstrap.sh`, `postcreate.sh`, `postCreateCommand` | nvm+Node, pyenv+Python, az, func, tofu, Playwright npm pkg | First container start |

**The pin bug to avoid:** a tool pinned in *both* phases. Whichever phase runs
last wins, and the earlier pin becomes a lie. Every tool gets exactly **one**
pin location — see the inventory below.

---

## Non-negotiable rules

| # | Rule |
|---|---|
| **R1** | Every tool has exactly one pin file. Not two. |
| **R2** | The tag `commands.sh` pushes MUST match the tag `devcontainer.json` references. `:latest` in one and only a dated tag in the other = stale image on next rebuild. |
| **R3** | `--no-cache` stays. A cached layer can silently preserve an old pin after you bump it. |

---

## Pin inventory (the contract)

| Tool | Pinned in | Version |
|---|---|---|
| Base image | `Dockerfile` `FROM` | `playwright:v1.63.0-noble@sha256:…` |
| nvm | `bootstrap.sh` | `v0.40.3` |
| Node | `bootstrap.sh` (nvm) | `24.10.0` |
| pyenv | `bootstrap.sh` | `v2.7.3` |
| Python | `bootstrap.sh` (pyenv) | `3.14.6` |
| pytest | `bootstrap.sh` (pip) | `9.0.3` |
| pre-commit | `bootstrap.sh` (pip) | `4.2.0` |
| Azure CLI | `bootstrap.sh` (apt) | `2.88.0` |
| Azure Functions | `bootstrap.sh` (npm) | `4.15.2` |
| OpenTofu | `bootstrap.sh` (binary release) | `1.13.1` |
| Playwright (JS pkg) | `bootstrap.sh` (npm) | `1.63.0` |
| Image tag pushed | `commands.sh` | date + `latest` |

---

## Overlaps to watch before editing a pin

**1. Playwright lives in two places.**
- `Dockerfile` → `mcr.microsoft.com/playwright:v1.63.0-noble`
- `bootstrap.sh` → `PLAYWRIGHT_VERSION=1.63.0`

These **must match**. If they diverge, `npm install` pulls a `@playwright/test`
built against different browser binaries than the ones baked into the base
image → `browser not found` / `executable doesn't exist` at test time.
Change both or neither.

**2. Node lives in two places.**
- Base Playwright image ships its own Node.
- `bootstrap.sh` installs nvm + Node 24.10.0.

Intentional, but `bootstrap.sh` must run *before* anything calls `node`.
If a `postCreateCommand` runs npm before bootstrap, it uses the image's Node
and silently bypasses the pin.

**3. Exactly one `devcontainer.json` may be authoritative.**
Dead config is where pins rot. Delete the other.

**4. `:latest` does not re-pull on container open.**
A devcontainer pinned to `:latest` reuses the local copy until an explicit
rebuild. Bumping a pin in `bootstrap.sh` does NOT propagate to existing devs.

---

## Build context gotchas

The build context is `.devcontainer`, **not** the repo root. Consequences:

- `COPY foo bar` in `Dockerfile` resolves relative to `.devcontainer/`.
- `.dockerignore` is read from `.devcontainer/.dockerignore`, not repo root.
- Files under `.devcontainer/build/` are **inside the context**. `.dockerignore`
  must list `.repos` and `build`, or you ship `commands.sh` and the local
  `devcontainer.json` inside the image layers.

---

## Consuming the image (pinning)

After `commands.sh` prints `pinned: "sha256:…"`, pin that digest in
`.devcontainer/devcontainer.json`:

```jsonc
{
  "image": "ghcr.io/athithya-sakthivel/agentic-devcontainer:2026.10.02@sha256:<digest>",
  // remove the "build" block
}
```

The digest is immutable; the date tag is a rollback alias. Pin the digest,
keep the tag for human readability.

---

## Workflow

```bash
# 1. Build + push
export GIT_PAT=ghp_...
.devcontainer/build/commands.sh

# 2. Copy the printed digest into devcontainer.json (see above)

# 3. Force devs to pick up the new image
#    VS Code → "Dev Containers: Rebuild Container Without Cache"
```

Two pushes on the same UTC day overwrite the dated tag. That is intentional —
the date tag is a rollup alias, not a unique build id. Add a `$GIT_SHA` tag
if you need per-commit traceability.
