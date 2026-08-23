# Shell Tab-Completion for `nws`

**Date:** 2026-08-12
**Status:** Ready for implementation
**Directory:** /home/alexfneves/gits/nws

## Intent

Give `nws` native tab-completion in bash, zsh, and fish by shipping static
completion files from the `main` derivation's `share/` tree (so both
`nix profile install .#main` and the devenv devShell auto-expose them). The
main interactive flow — `nws unregister <TAB>` — should complete against the
currently registered workspace canonical paths (from `nws list`) whenever the
daemon is reachable, and always degrade gracefully to plain filesystem
completion when it is not (never hang, never error). Completions are pure
static text files; **no Odin source changes** and **no runtime subcommand**.

## User Story

As a `nws` user, I want to hit `Tab` to complete subcommands and paths, so
that I don't have to remember/type the full command, and I want to see my
actual registered workspaces when I `unregister <TAB>`, without completion
freezing or failing when the daemon is down.

## Behavior

### Happy Path
1. `nws <TAB>` → `service register unregister list help` (subcommand names,
   tracking the `nws help` usage text).
2. `nws service <TAB>` / `nws list <TAB>` / `nws help <TAB>` → no further
   tokens suggested.
3. `nws register <TAB>` → filesystem paths relative to cwd.
4. `nws unregister <TAB>` with the daemon running (whose `nws list` stdout
   starts with `OK`) → the registered workspace canonical paths, one per line
   from `nws list`, spaces preserved.
5. `nws unregister <TAB>` with the daemon down (or no registered name matches
   the typed prefix) → falls back to filesystem paths relative to cwd.

### Edge Cases & Error Handling
- **Daemon unreachable:** `nws list` prints `nws: cannot reach daemon on
  127.0.0.1:<port> - is the daemon running?` (single line, no `OK` header).
  Every shell's name-completion helper returns **no candidates** in that case,
  and the caller falls back to filesystem completion. `nws list` dials localhost
  and gets an **instant connection-refused** when the daemon is down, so no
  `timeout`-style wrapper is needed — nothing hangs.
- **Workspace path contains spaces:** candidates are parsed line-by-line
  (bash `while read`, zsh `compadd -a`, fish `for line`), never `compgen -W` /
  whitespace-split, so spaces survive.
- **Registered list empty but daemon up (`OK 0`):** name helper emits nothing →
  filesystem fallback applies.
- **No type-prefix match** on `unregister`: name candidates empty for that
  prefix → filesystem fallback applies.
- **Unknown first token** (any string not in the list): completion simply
  offers nothing / files, matching the CLI's own unknown-command error; the
  static wordlist makes the valid set authoritative.

## Scope

### In Scope
- In-tree completion scripts: `completions/bash/nws`,
  `completions/zsh/_nws`, `completions/fish/nws.fish`.
- `flake.nix`: a `completions` `runCommand` derivation (mirroring
  `systemdUnit`) copying the three in-tree files into the standard `share/`
  dirs, and `main.installPhase` copying `${completions}/share/*` into `$out/share/`.
- Test harness `tests/completions_test.sh` wired into `enterTest` (bash source
  + fish/zsh subtests when those interpreters are available), and adding
  `pkgs.fish`/`pkgs.zsh` to the devShell so the tests run.
- README: shell pre-requisites (zsh `compinit`, bash-completion presence,
  fish auto-load) + daemon-reachable caveat for name completion.
- Manual verification checklist update.

### Out of Scope
- A runtime `nws completions <bash|zsh|fish>` subcommand (static shipping is
  the chosen mechanism; no Odin changes at all).
- Completing `list` against registered names (it takes no argument).
- `register` completing against registered names (it takes a filesystem PATH).

## Effort & Quality
- **Level:** MVP
- **Tests:** thorough for bash (functional against a mocked `nws`); fish
  functional (mocked daemon up/down); zsh parse/load check. All invoked via
  `devenv test` after the existing Odin unit tests (`enterTest`).
- **Docs:** README additions + manual verification checklist in this plan.

## Constraints
- Must work through both `nix profile install .#main` **and** the devenv
  devShell (`packages = [ main ... ]`) — both consume `main`'s `share/` tree.
- Must stay conservative: a missing/broken daemon must never hang or error a
  completion — **fall back, don't fail**.
- No Odin source changes; `src/` and `tests/*_test.odin` untouched.
- Per `AGENTS.md`: after editing `flake.nix`, re-run `devenv test` to confirm
  the `enterTest` hook works (it now also runs the completion test).
- The odin-fmt git hook only matches `\.odin$`, so the new bash/zsh/fish files
  and the `.sh` test won't be touched by it.

## Ideal State Criteria

### Core Functionality
- [ ] ISC-1: First token completes to exactly `service register unregister list help`.
- [ ] ISC-2: `register` completes filesystem paths relative to cwd.
- [ ] ISC-3: `unregister` completes registered workspace canonical paths when `nws list` first line starts with `OK`.
- [ ] ISC-4: `unregister` falls back to filesystem completion when `nws list` does not start with `OK` (daemon down).
- [ ] ISC-5: `service`, `list`, `help` offer no further tokens.

### Edge Cases
- [ ] ISC-6: Workspace paths containing spaces are completed verbatim (not split).
- [ ] ISC-7: `unregister` with no prefix-match among registered names falls back to filesystem.

### Quality / Packaging
- [ ] ISC-8: The three files land in `main`'s `share/{bash-completion/completions,zsh/site-functions,fish/vendor_completions.d}` under the correct names (`nws`, `_nws`, `nws.fish`), verified via `nix build .#main` (and `. #completions` standalone).
- [ ] ISC-9: `devenv test` runs `odin test tests` then `tests/completions_test.sh`, and passes (bash fully; fish/zsh subtests when installed).
- [ ] ISC-10: README documents zsh `compinit`, bash-completion, fish auto-load, and the daemon-reachable caveat.

### Anti-Criteria
- [ ] ISC-A-1: No Odin source file is modified.
- [ ] ISC-A-2: No completion can hang or error when the daemon is unreachable.
- [ ] ISC-A-3: No completion script is whitespace-split (paths with spaces must survive).

## Approach

**Static completion scripts shipped from the `main` derivation's `share/`
tree.** Scripts are kept **in-tree** under `completions/{bash,zsh,fish}/` (so
they are version-controlled and directly sourceable by the test harness), and
a `completions` `runCommand` derivation (symmetric with the existing
`systemdUnit` pattern) copies them into the three standard share dirs. `main`
then copies `completions`' `share/*` into `$out/share/`, so **both**
`nix profile install .#main` and the devenv profile pick them up (Nix exports
`XDG_DATA_DIRS` / zsh `fpath`; fish scans `vendor_completions.d`).

Live-name completion for `unregister` calls `nws list`, which returns
`OK <count>` then one canonical path per line. Every shell's helper treats
"first line does not start with `OK`" as "daemon unreachable" → emit nothing →
caller falls back to filesystem. Because `nws list` gets an instant
connection-refused when the daemon is down (localhost dial), no external
`timeout` wrapper is required; the project's own daemon always replies when up.

### Key Decisions
- **Static files, not a runtime subcommand** — because both install paths
  auto-merge `share/`, no Odin code, and the project's "minimal" ethos.
- **In-tree scripts + `completions` derivation (not inline heredocs)** — so the
  scripts are reviewable and the test harness can `source` them directly.
- **Live-name completion for `unregister`, filesystem fallback** — better UX
  for the main flow, with a strictly non-blocking fallback (ISC-4/7).
- **`register` = filesystem only** — it takes a PATH in the filesystem, not a
  registered name.

### Architecture
New repo layout:
```
completions/
  bash/nws          -> share/bash-completion/completions/nws
  zsh/_nws          -> share/zsh/site-functions/_nws
  fish/nws.fish     -> share/fish/vendor_completions.d/nws.fish
tests/completions_test.sh   # bash harness (sources/asserts the scripts)
```

`flake.nix` changes (full snippet in the todo):
```nix
# near systemdUnit
completions = pkgs.runCommand "nws-completions" { } ''
  mkdir -p $out/share/bash-completion/completions \
           $out/share/zsh/site-functions \
           $out/share/fish/vendor_completions.d
  cp ${./completions}/bash/nws      $out/share/bash-completion/completions/nws
  cp ${./completions}/zsh/_nws      $out/share/zsh/site-functions/_nws
  cp ${./completions}/fish/nws.fish $out/share/fish/vendor_completions.d/nws.fish
'';
# main.installPhase, appended:
#   mkdir -p $out/share
#   cp -r ${completions}/share/* $out/share/
# default = main  (unchanged)
```
devShell module:
```nix
packages = [ self.packages.${system}.main pkgs.fish pkgs.zsh ];
enterTest = ''
  odin test tests -collection:nwscore=src
  bash ${./tests/completions_test.sh}
'';
```

### Data Flow (completion-time)
`unregister` name completion: shell helper → `nws list` (localhost TCP) →
stdout starts `OK`? → yes: candidates = lines 2..n (stripped of `OK <count>`
header) → offered; no/other: helper emits nothing → filesystem fallback.
`register`/fallback: `compgen -f` (bash) / `_files` (zsh) / `__fish_complete_path`
+ native files (fish) relative to cwd.

## Dependencies
- No new runtime dependencies. Test concurrency: `bash` (always present),
  `fish`, `zsh` (added to devShell `packages` so the subtests can run).
- File paths must be present in the flake's `src = ./.` context (they are).

## Risks & Open Questions
- **Risk: zsh functional coverage is light** (parse/load check only; fully
  evaluating `_describe`/`_files`/`compadd` candidates requires compinit
  scaffolding). Mitigation: `zsh -n` parse check + the bash/fish subtests prove
  the shared logic (subcommand list, `OK`-header detection, fallback); zsh's
  branch structure mirrors them. Accepted.
- **Risk: `compopt -o default` readline behavior isn't observable in a
  non-interactive test.** Mitigation: bash scripts **materialize `COMPREPLY`
  explicitly** (`COMPREPLY=( $(compgen -f -- "$cur") )`) instead of relying on
  readline's default-completion, making the fallback directly assertable.
  Accepted.
- **Risk: fish load-time evaluation of `-a "(...)"`/`-n` strings.** Mitigation:
  define `_nws_registered_ws` **before** the `complete` lines in `nws.fish`, and
  redirect test-source stderr. In production the fish completion functions are
  always present. Accepted.
- **Assumption: `nws list` output shape** (`OK <count>` header, one path/line,
  `nws: cannot reach daemon...` on failure) — verified in
  `src/nix_workspace.odin:261` (`cmd_list`) and `list_reply`
  (`src/nix_workspace.odin:507`). If it changes, only the `OK*`-prefix check in
  the three scripts needs updating.

---

## Todos (tagged `completions`)

Each todo below is independently executable by a worker. Order matters (build
files first, then flake, then tests, then docs). Run `devenv test` and
`nix build .#main` after wiring.

### C-1: Add `completions/bash/nws`
**Files to create:** `completions/bash/nws`

Bash completion for the first token (subcommands) and the PATH arg. Must
materialize `COMPREPLY` explicitly (no dependence on readline default
completion) so the fallback is testable. Tracks `nws help`'s subcommand list:
`service register unregister list help`.

```bash
# bash completion for nws
# Installed to share/bash-completion/completions/nws
# Tracks `nws help`'s subcommand list: service register unregister list help.
# register/unregister take an optional PATH; unregister also completes against
# registered workspace canonical paths from `nws list` when the daemon is
# reachable, falling back to filesystem completion otherwise.

_nws() {
    local cur sub
    cur="${COMP_WORDS[COMP_CWORD]}"
    sub="${COMP_WORDS[1]}"

    # First token: complete subcommand names.
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "service register unregister list help" -- "$cur") )
        return
    fi

    case "$sub" in
        register)
            # filesystem path relative to cwd
            COMPREPLY=( $(compgen -f -- "$cur") )
            ;;
        unregister)
            _nws_registered
            # Fall back to filesystem when the daemon is unreachable or no
            # registered name matches the current prefix.
            if (( ${#COMPREPLY[@]} == 0 )); then
                COMPREPLY=( $(compgen -f -- "$cur") )
            fi
            ;;
        *)  # service, list, help: no further tokens
            COMPREPLY=()
            ;;
    esac
}

# Fill COMPREPLY with registered workspace canonical paths. Emits nothing and
# leaves COMPREPLY empty when the daemon is unreachable (stdout won't start OK).
_nws_registered() {
    local out line
    out=$(nws list 2>/dev/null) || { COMPREPLY=(); return; }
    [[ "$out" == OK* ]] || { COMPREPLY=(); return; }
    COMPREPLY=()
    while IFS= read -r line; do
        [[ "$line" == OK* ]] && continue     # skip the "OK <count>" header
        [[ -n "$line" ]] || continue
        # include only lines sharing the current prefix (spaces preserved)
        [[ "$line" == "$cur"* ]] && COMPREPLY+=( "$line" )
    done <<< "$out"
}

complete -F _nws nws
```
**Do NOT:**
- modify any file under `src/` or `tests/*_test.odin` (ISC-A-1);
- use `compgen -W` for workspace paths (splits on whitespace — ISC-A-3);
- hang on a missing daemon (IST-A-2) — the `OK*` guard already covers it.

**Acceptance:** satisfies ISC-1, ISC-2, ISC-3, ISC-4, ISC-5, ISC-6, ISC-7 for
bash. Verify by sourcing and calling `_nws` with `COMP_WORDS`/`COMP_CWORD` set
exactly as in `tests/completions_test.sh`.

### C-2: Add `completions/zsh/_nws`
**Files to create:** `completions/zsh/_nws`

Zsh completion via `#compdef nws`. Must NOT self-invoke `_nws "$@"` at the
bottom (compinit invokes it). Uses `_describe` for token 1, `_files` for
register/fallback, and `compadd -a` for registered names.

```zsh
#compdef nws
# zsh completion for nws (share/zsh/site-functions/_nws)
# Requires: autoload -Uz compinit && compinit (standard on NixOS/home-manager).
# Tracks `nws help`'s subcommand list; register completes files; unregister
# completes registered canonical paths from `nws list` when the daemon is
# reachable, falling back to filesystem completion.

_nws() {
    local -a cmds
    cmds=(service register unregister list help)

    if (( CURRENT == 2 )); then
        _describe 'command' cmds
        return
    fi

    case $words[2] in
        register)
            _files
            ;;
        unregister)
            if _nws_registered && (( ${#_nws_ws[@]} > 0 )); then
                compadd -a _nws_ws
            else
                _files   # fallback: filesystem when daemon unreachable
            fi
            ;;
        *)  # service, list, help: no further tokens
            ;;
    esac
}

# Sets $_nws_ws (array of registered workspace canonical paths). Leaves it
# empty when the daemon is unreachable (stdout won't start with "OK").
_nws_registered() {
    local out line
    _nws_ws=()
    out=$(nws list 2>/dev/null) || return 1
    [[ "$out" == OK* ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == OK* ]] && continue     # skip "OK <count>" header
        [[ -n "$line" ]] || continue
        _nws_ws+=( "$line" )
    done <<< "$out"
    return 0
}
```
**Do NOT** append `_nws "$@"` at the end. **Do NOT** use `compadd` on a
whitespace-split wordlist for paths (ISC-A-3) — use the `-a` array.

**Acceptance:** satisfies ISC-1/3/4/5/6/7 for zsh; passes `zsh -n` parse check
(ISC-9).

### C-3: Add `completions/fish/nws.fish`
**Files to create:** `completions/fish/nws.fish`

Fish completion, auto-loaded from `vendor_completions.d`. **Define the helper
function BEFORE the `complete` lines** (robustness/testability). `unregister`
line omits `-f` so fish's native file completion acts as the fallback when
`_nws_registered_ws` emits nothing.

```fish
# fish completion for nws (Nix Workspace Root Manager).
# Auto-loaded from vendor_completions.d. Tracks `nws help`'s subcommand list:
# service register unregister list help.
# register: filesystem path. unregister: registered workspace canonical paths
# from `nws list` when the daemon is reachable, plus native file completion as
# fallback when it is not.

function _nws_registered_ws
    set -l out (nws list 2>/dev/null)
    if set -q out[1]; and string match -q 'OK*' -- "$out[1]"
        for line in $out[2..-1]
            printf '%s\n' "$line"
        end
    end
    # Daemon unreachable: `nws list` prints one non-"OK" line, so this emits
    # nothing and fish's native file completion applies instead.
end

# Token 1: subcommand names.
complete -c nws -f -n "__fish_use_subcommand" \
    -a "service register unregister list help"

# register: filesystem path.
complete -c nws -f -n "__fish_seen_subcommand_from register" \
    -a "(__fish_complete_path)"

# unregister: registered names from `nws list`, plus native files as fallback
# (this line intentionally omits -f so file completion stays enabled).
complete -c nws -n "__fish_seen_subcommand_from unregister" \
    -a "(_nws_registered_ws)"
```
**Acceptance:** satisfies ISC-1/2/3/4/5/6/7 for fish; `_nws_registered_ws`
emits the two names with the mock daemon up and nothing with it down (ISC-9).

### C-4: Wire `completions` derivation into `flake.nix`
**Files to modify:** `flake.nix` (only).

Add a `completions = pkgs.runCommand "nws-completions" { } '' ... '';` to
`packages.${system}.{ rec = { ... } }` beside `systemdUnit` (see the
Architecture snippet), copying the three in-tree files into the standard share
dirs. Then in `main.installPhase`, append a copy of `${completions}/share/*`
into `$out/share/`. Add `pkgs.fish` and `pkgs.zsh` to the devShell module's
`packages`, and extend `enterTest` to run the completion test after the Odin
tests:

```nix
enterTest = ''
  odin test tests -collection:nwscore=src
  bash ${./tests/completions_test.sh}
'';
```
Keep the existing `odin build src/nix_workspace.odin -file
-collection:nwscore=src -out:build/nws` line in `installPhase` unchanged.
**Do NOT** add heredoc completion content inline in `installPhase` (scripts are
in-tree and referenced from the `completions` derivation).

**Acceptance:** `nix build .#main` produces
`result/share/{bash-completion/completions/nws,zsh/site-functions/_nws,fish/vendor_completions.d/nws.fish}`,
and `nix build . #completions` (i.e. `.\#completions`) produces the standalone
tree (ISC-8).

### C-5: Add the test harness `tests/completions_test.sh`
**Files to create:** `tests/completions_test.sh`

Bash harness that sources each completion against a mocked `nws` (an
executable on PATH whose `nws list` prints `OK 2\n/home/user/a repo\n/home/user/other`
when `MOCK_DAEMON_UP` is set, else the `cannot reach daemon` line). Assert:
bash subcommand token-1 → all five; register → files; unregister daemon-up →
names (with a space); unregister daemon-down → filesystem fallback; service/
list/help → no tokens. The **bash subtest is wrapped in `if type compgen`** so it
skips on a bash built without programmable completion (same spirit as the
fish/zsh interpreter skips) instead of failing `devenv test`.
bash subcommand token-1 → all five; register → files; unregister daemon-up →
names (with a space); unregister daemon-down → filesystem fallback; service/
list/help → no tokens. Fish subtest invokes `_nws_registered_ws` via
`fish -c` (daemon up/down). Zsh subtest runs `zsh -n "$COMP/zsh/_nws"` (skip if
`fish`/`zsh` not installed). Exit non-zero on any failure.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMP="$ROOT/completions"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$*"; }

mock_dir="$(mktemp -d)"; trap 'rm -rf "$mock_dir"' EXIT
cat > "$mock_dir/nws" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  list)
    if [[ -n "${MOCK_DAEMON_UP:-}" ]]; then
      printf 'OK 2\n/home/user/a repo\n/home/user/other\n'
    else
      printf 'nws: cannot reach daemon on 127.0.0.1:17424 - is the daemon running?\n'
    fi ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$mock_dir/nws"; export PATH="$mock_dir:$PATH"

work="$(mktemp -d)"; mkdir -p "$work/repo dir"; touch "$work/alpha.txt" "$work/beta.txt"
cd "$work"

if type compgen >/dev/null 2>&1; then  # bash w/ programmable completion
printf '== bash ==\n'; source "$COMP/bash/nws"
COMP_WORDS=(nws ""); COMP_CWORD=1; COMPREPLY=(); _nws
for c in service register unregister list help; do
  [[ " ${COMPREPLY[*]} " == *" $c "* ]] && ok "bash subcmd '$c'" || bad "bash subcmd '$c': ${COMPREPLY[*]}"
done

COMP_WORDS=(nws register ""); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *" alpha.txt "* ]] && ok "bash register files" || bad "bash register files: ${COMPREPLY[*]}"

export MOCK_DAEMON_UP=1
COMP_WORDS=(nws unregister ""); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *"/home/user/a repo"* ]] && ok "bash unregister name (spaces)" || bad "bash unregister name: ${COMPREPLY[*]}"

unset MOCK_DAEMON_UP
COMP_WORDS=(nws unregister ""); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *" alpha.txt "* ]] && ok "bash unregister fallback files" || bad "bash unregister fallback: ${COMPREPLY[*]}"

for s in service list help; do
  COMP_WORDS=(nws "$s" ""); COMP_CWORD=2; COMPREPLY=(); _nws
  [[ ${#COMPREPLY[@]} -eq 0 ]] && ok "bash $s no-token" || bad "bash $s no-token: ${COMPREPLY[*]}"
done
else printf 'skip - bash lacks programmable completion (no compgen)\n'; fi

if command -v fish >/dev/null 2>&1; then
  printf '== fish ==\n'
  export MOCK_DAEMON_UP=1
  o="$(fish -c 'source '"$COMP"'/fish/nws.fish 2>/dev/null; _nws_registered_ws' 2>/dev/null)"
  [[ "$o" == *"/home/user/a repo"* ]] && ok "fish names (daemon up)" || bad "fish names: $o"
  unset MOCK_DAEMON_UP
  o="$(fish -c 'source '"$COMP"'/fish/nws.fish 2>/dev/null; _nws_registered_ws' 2>/dev/null)"
  [[ -z "$o" ]] && ok "fish names empty (daemon down)" || bad "fish names not empty: $o"
else printf 'skip - fish not installed\n'; fi

if command -v zsh >/dev/null 2>&1; then
  printf '== zsh ==\n'
  zsh -n "$COMP/zsh/_nws" && ok "zsh parse check" || bad "zsh parse check"
else printf 'skip - zsh not installed\n'; fi

printf -- '----\ncompletion tests: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```
**Must** follow the exact bash fallback style in C-1 (explicit `COMPREPLY`
assignment) so these assertions pass. Each subtest (bash/fish/zsh) may be
skipped when its interpreter or programmable-completion support is absent.
**Acceptance:** `bash tests/completions_test.sh` exits 0 (`ok` or `skip` for
every check, never `FAIL`) (ISC-9); on a bash with programmable completion
the bash subtest RAN its assertions (PASS>0).

### C-6: README + manual verification checklist
**Files to modify:** `README.md`, and append to the manual checklist section of
`.pi/plans/2026-08-11-nws/completions-plan.md` (or the repo's runbook if it
exists).

Document (ISC-10):
- zsh must run `autoload -Uz compinit && compinit` (NixOS/home-manager default);
- bash needs `bash-completion` installed (present in NixOS and this devenv);
- fish auto-loads `vendor_completions.d` — nothing to enable;
- `unregister` name completion needs the daemon reachable; it falls back to
  filesystem when it isn't.

Manual verification steps to add to the checklist:
1. `nix build .#main`, then `nix profile install .#main` (or `devenv up`).
2. bash: `nws <TAB><TAB>` → five subcommands; `nws register <TAB>` → files;
   `nws unregister <TAB>` → registered names with daemon up; names→files with
   daemon down.
3. Confirm `result` (or the installed profile share tree) contains all three
   files under the correct names (ISC-8).
4. `devenv test` passes (Odin unit tests + completion harness) (ISC-9).

**Acceptance:** README covers the four docs points; checklist updated.

---

## Execution Notes
- Follow AGENTS.md: work `src = ./.` is fine; after flake.nix edits run
  `devenv test` and `nix build .#main`; run `nix develop --command odinfmt ...`
  only if you touch `.odin` (you won't).
- No Odin files change anywhere in this plan (ISC-A-1).

---

## Manual verification checklist

Runbook for manually confirming the shipped completions end-to-end (covers
ISC-1..ISC-9):

1. `nix build .#main`, then `nix profile install .#main` (or `devenv up` to get
   the devShell/daemon instead).
2. **bash:** `nws <TAB><TAB>` → the five subcommands
   `service register unregister list help`; `nws register <TAB>` → filesystem
   paths; `nws unregister <TAB>` → registered workspace names with the daemon
   up, and filesystem paths (fallback) with the daemon down.
3. Confirm the three files land under `result/share/` with the correct names:
   `result/share/bash-completion/completions/nws`,
   `result/share/zsh/site-functions/_nws`,
   `result/share/fish/vendor_completions.d/nws.fish` (or inspect the installed
   profile's share tree the same way).
4. `devenv test` passes — Odin unit tests first, then the completion harness
   (`tests/completions_test.sh`), with bash assertions running (and fish/zsh
   subtests when those interpreters are installed).
