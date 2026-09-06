#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# devenv bakes ${./tests/completions_test.sh} as a flat store copy whose
# parent is /nix/store; fall back to the repo root we were launched from.
[[ -d "$ROOT/completions" ]] || ROOT="$PWD"
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
for c in service register unregister list version help; do
  [[ " ${COMPREPLY[*]} " == *" $c "* ]] && ok "bash subcmd '$c'" || bad "bash subcmd '$c': ${COMPREPLY[*]}"
done

COMP_WORDS=(nws register ""); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *" alpha.txt "* ]] && ok "bash register files" || bad "bash register files: ${COMPREPLY[*]}"

COMP_WORDS=(nws register --dev-shell-p); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *" --dev-shell-packages "* ]] && ok "bash register flag --dev-shell-packages" || bad "bash register flag --dev-shell-packages: ${COMPREPLY[*]}"

export MOCK_DAEMON_UP=1
COMP_WORDS=(nws unregister ""); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *"/home/user/a repo"* ]] && ok "bash unregister name (spaces)" || bad "bash unregister name: ${COMPREPLY[*]}"

unset MOCK_DAEMON_UP
COMP_WORDS=(nws unregister ""); COMP_CWORD=2; COMPREPLY=(); _nws
[[ " ${COMPREPLY[*]} " == *" alpha.txt "* ]] && ok "bash unregister fallback files" || bad "bash unregister fallback: ${COMPREPLY[*]}"

for s in service list version help; do
  COMP_WORDS=(nws "$s" ""); COMP_CWORD=2; COMPREPLY=(); _nws
  [[ ${#COMPREPLY[@]} -eq 0 ]] && ok "bash $s no-token" || bad "bash $s no-token: ${COMPREPLY[*]}"
done
else printf 'skip - bash lacks programmable completion (no compgen)\n'; fi

# Static coverage: the flag must be present in every completion file even when
# the shell isn't installed (guards zsh/fish regressions that live checks can't
# catch). Runs before the shell-dependent sections so it works regardless.
printf '== static flag coverage ==\n'
for f in bash/nws zsh/_nws fish/nws.fish; do
  if grep -q -- '--dev-shell-packages' "$COMP/$f"; then
    ok "--dev-shell-packages in $f"
  else
    bad "--dev-shell-packages missing in $f"
  fi
done

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
