# blackmatter-tend — Claude Orientation

> **★★★ CSE / Knowable Construction.** This repo operates under **Constructive Substrate Engineering** — canonical specification at [`pleme-io/theory/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md`](https://github.com/pleme-io/theory/blob/main/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md). The Compounding Directive (operational rules: solve once, load-bearing fixes only, idiom-first, models stay current, direction beats velocity) is in the org-level pleme-io/CLAUDE.md ★★★ section. Read both before non-trivial changes.


One-sentence purpose: home-manager service for the `tend` daemon —
workspace repo sync + version-watch daemon (launchd agent on Darwin,
systemd user service on Linux).

## Classification

- **Archetype:** `blackmatter-component-hm-only`
- **Flake shape:** `substrate/lib/blackmatter-component-flake.nix`
- **Option namespace:** `blackmatter.components.tend`
- **Upstream CLI:** `tend` from `github:pleme-io/tend` (built from source
  via `pkgs.tend`, available on the user's `$PATH`).

## Where to look

| Intent | File |
|--------|------|
| HM option schema + service wiring | `module/default.nix` |
| Workspace config schema | `~/.config/tend/config.yaml` (generated) |
| Flake surface | `flake.nix` |

## What NOT to do

- Don't inline workspace definitions (org paths, daemon tokens). Those are
  private and live in `nix` repo SOPS.
- Don't add hooks that race with the daemon's own reconciliation loop.
