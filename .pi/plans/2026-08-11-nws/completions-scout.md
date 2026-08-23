# Context for: adding shell tab-completion to the `nws` CLI

Focused recon for planning shell tab-completion (bash/zsh/fish) for `nws`.
No code changed. Everything below was verified against the actual repo.

## 1. CLI surface (exact)

`main()` in `src/nix_workspace.odin` reads `os.args[1:]` and `switch args[0]`
on the **first token only**. Args after that are consumed ad-hoc per command.

- `service` — daemon; takes **no** further args. (`run_service()`)
- `register [PATH]` — optional `args[1]`, default `""` → `resolve_path` falls
  back to `$PWD` (`cmd_register`). Only the first extra arg is read; any
  further args are silently ignored.
- `unregister [PATH]` — identical shape to `register` (`cmd_unregister`).
- `list` — no args (`cmd_list`).
- `help` / `--help` / `-h` — all three spellings print usage (`print_usage`).
- default (`case:`) — prints `nws: unknown command: <arg>` + usage. Exit code
  is not meaningful (no `os.exit`; just falls off the end of `main`).

**Arg parsing facts (matter for completion design):**
- No flags, no `-`-prefixed option parsing anywhere. Anything after the
  subcommand that isn't the single PATH arg is ignored.
- `register` / `unregister` PATH arg is a **filesystem path**
  (`normalize_path` → `filepath.abs` + `filepath.clean`). Incomplete paths are
  completed relative to cwd — **filesystem completion is correct here**.
- `list` and `unregister` *could* complete against registered workspace names
  obtained from `nws list`, but see the daemon-dependency caveat in §4.
- `service`/`help`/`list` take no PATH → no further completion tokens.

**Subcommand-name completion (first token):** complete `service register
unregister list help` (and arguably `--help -h`). The default/unknown branch
means any other string is an error, so restricting completion to these is safe.

## 2. Shell completion options (research + Nix reality)

The idiomatic Nix way to ship completions is **static files in the
derivation's `share/` tree** under three standard locations. Verified these
locations exist in the project's own devenv profile
(`/nix/store/4p8s60bzb9gfji8xi67a4rs6pjf46vgn-devenv-profile/share/`), merged
automatically from installed packages:

- **bash**: `share/bash-completion/completions/nws`
  (basename = binary name, no shell suffix or `.bash`). Picked up by the
  Nix-packaged `bash-completion` via `XDG_DATA_DIRS` (profile.d hook).
  Filenames in the devenv profile follow `process-compose.bash` / `prek.bash`,
  but the standard bash-completion convention is `completions/<binary>` (no
  extension) — both work; `/nix/store/...git.../share/bash-completion/completions/git`
  is an example of the no-extension form.
- **zsh**: `share/zsh/site-functions/_nws` (leading underscore). zsh `compinit`
  scans `fpath`; on Nix this dir is in `fpath` via `XDG_DATA_DIRS`
  (`site-functions` under `share/zsh`). Profile exemplars: `_process-compose`,
  `_prek`. Requires the user to have zsh completion initialized
  (`autoload -Uz compinit && compinit` in their zshrc, standard on NixOS/home-manager).
- **fish**: `share/fish/vendor_completions.d/nws.fish`. fish auto-loads
  `vendor_completions.d`. Profile exemplar: `process-compose.fish`.
- The `zsh-completions` nixpkgs package is an *alternative* channel (bundles
  third-party completions into one package), but it is not needed here — the
  direct `share/zsh/site-functions` route is simpler and self-contained in the
  derivation.

**Runtime `nws completions <bash|zsh|fish>` subcommand — weigh:**
Pro: single source of truth in the binary; no static files to keep in sync;
user can dump to a file or source directly. Con: (a) must be written and
maintained in Odin (the project deliberately keeps the binary slim); (b) the
user must still wire sourcing/`fpath`/`completions.d` manually — it does not
"just work" on `nix profile install` or `devenv up`; (c) more CLI surface to
test/version. For a flake-packaged binary the **statically-shipped files are
the idiomatic and lowest-friction choice**, because `nix profile install` and
devenv both merge `share/*` into the target shell automatically (verified for
the devenv profile). A runtime subcommand is a reasonable *optional extra* if
the team wants self-emission, but is not required for completion to work. Given
the "pure Odin, single binary, no generator lib" constraint and this repo's
"keep it minimal" ethos, **ship static files**; treat `nws completions` as an
optional add-on, not the primary mechanism.

## 3. Install / packaging (flake.nix)

`flake.nix` structure:
- `systemdUnit = pkgs.runCommand "nws-systemd-unit" { } ''...''` → produces
  `$out/share/systemd/user/nws.service`.
- `main = pkgs.stdenv.mkDerivation { ... installPhase = '' ... '' }`:
  builds the Odin binary with `odin build src/nix_workspace.odin -file
  -collection:nwscore=src -out:build/nws`, writes it to `$out/bin/`, and
  `cp ${systemdUnit}/share/systemd/user/nws.service $out/share/systemd/user/`.
  `default = main`.
- devenv devShell module: `packages = [ self.packages.${system}.main ]` —
  installs `main` **into the devenv profile**, so anything `main` ships under
  `share/` is exposed inside the devenv shell (verified: the devenv profile i
  already carries `share/bash-completion`, `share/zsh/site-functions`,
  `share/fish/vendor_completions.d`).
- Verified live: `result/bin/nws` (store `/nix/store/ippj…-main`) currently
  ships only `share/systemd` — no `share/bash-completion` etc. yet.

**Where to add completion files** so both `nix profile install .#main` and
`devenv up`/`devenv shell` expose them: add the three `share/…` dirs to the
`main` derivation (it is the derivation both install paths use). Two clean
options, matching the existing `systemdUnit` precedent:
1. **Inline in `main.installPhase`**: `mkdir -p $out/share/{bash-completion/completions, zsh/site-functions, fish/vendor_completions.d}` and `cat > … <<'EOF'` the scripts.
2. **Symmetric `completions` derivation** (like `systemdUnit`): a `runCommand`
   emitting all three files under `share/`, then `cp -r ${completions}/share/* $out/share/` in `main.installPhase`. Keeps `flake.nix` declarative and mirrors the existing unit pattern, but `main` would have to merge/copy them in (as it already does for the unit).

Option 1 is simplest (no cross-derivation copy); option 2 is more declarative
and lets `nix build .#completions` produce the files standalone. Either exposes
completions through both `nix profile install .#main` and devenv, because both
consume `main`'s `share/` tree.

**How devenv/shells make them available** (verified): the devenv profile
contains `share/bash-completion/completions`, `share/zsh/site-functions`,
`share/fish/vendor_completions.d`, populated by installed packages. Nix's
profile/nix-develop machinery sets `XDG_DATA_DIRS` (and zsh `fpath` /
bash-completion's profile.d hook reads these dirs), so files land in exactly
the dirs the shells scan. Same mechanism applies to `nix profile install`.

## 4. Dependencies / constraints

- Pure Odin, single binary, no external completion-generator library in play.
  Completions are **just static text files** — no Odin dependency, no `src/`
  change required at all if shipped statically.
- `register`/`unregister` PATH completion = filesystem (`compgen -f` bash /
  `_files` or `_path_files` zsh / `__fish_complete_path` fish), defaulting to
  cwd when empty. Subcommand-name completion for the first token.
- **Caveat on `unregister`/`list` against registered names:** doing this well
  requires the completion script to shell out to `nws list`, which needs the
  **daemon running and reachable on `127.0.0.1:<port>`** (config port, default
  17424). When the daemon is down, `cmd_list` prints a "cannot reach daemon"
  error. Design decision for the planner: either (a) keep it simple — only
  filesystem-complete the PATH arg and statically list subcommands, or (b)
  attempt `nws list` and gracefully fall back to filesystem when the daemon
  isn't reachable. (b) gives better UX but adds runtime coupling/complexity to
  each shell script.
- Must remain conservative like the rest of the project: a bad/missing daemon
  must not make completion hang or error out — fall back, don't fail.
- `enterTest` = `odin test tests -collection:nwscore=src` is unaffected by
  static completion files (no Odin test target changes). `src/core/*.odin` and
  `src/nix_workspace.odin` stay untouched for a static-shipping approach.
- odin-fmt git hook only matches `\.odin$` files (`git-hooks.hooks.odin-fmt.files`
  = `"\\.odin$"`), so adding non-`.odin` completion scripts won't trigger it.
- Per AGENTS.md: **if flake.nix is extended, run `devenv test` after** to
  confirm the `enterTest` hook still works, and update the manual verification
  checklist in the plan.
- `nws help` output (the usage text) is the single source of truth for the
  subcommand list — completion wordlists should track it (`service register
  unregister list help`).

## Gotchas

- Completion scripts will be brand-new files (bash/zsh/fish syntax) in a repo
  that so far only has Odin + Nix — no existing completion code or style to
  follow; keep each script minimal.
- Don't add completion files under `src/` or `tests/`; they belong in
  `flake.nix`'s installPhase (or a `completions` derivation) and only exist in
  the built store path, not in the working tree — so there's no "where do the
  files live" ambiguity. (If the team prefers keeping them in-tree, they'd need
  `src = ./.` to pick them up and an installPhase `cp`; the flake already sets
  `src = ./.`.)
- Store-path purity: `main` must own all completion files in `$out/share`.
  Any separate `completions` derivation must be `cp`'d into `main` (exactly the
  `systemdUnit` pattern), otherwise `nix profile install .#main` won't ship them.
- zsh completion requires the user's zsh to run `compinit`; fish loads
  `vendor_completions.d` by default; bash needs `bash-completion` (present in
  NixOS/home-manager and in this devenv profile). These are user-shell
  prerequisites, not something the flake can force — document them in README.
