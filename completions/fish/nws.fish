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

# register: filesystem path, plus overlay flags when the word starts with "--".
complete -c nws -f -n '__fish_seen_subcommand_from register; and string match -q -- "-*" (commandline -ct)' \
    -a "--overlay\tURL of an overlay flake --attr-path\tattribute path for the last --overlay --overlay-attr\toverlay attribute name --no-flake\tnon-flake overlay expression --nixpkgs\tnixpkgs URL --resolver\texternal resolver script --dev-shell-packages\tcomma-separated attrs for the managed devShell"
complete -c nws -f -n "__fish_seen_subcommand_from register" \
    -a "(__fish_complete_path)"

# unregister: registered names from `nws list`, plus native files as fallback
# (this line intentionally omits -f so file completion stays enabled).
complete -c nws -n "__fish_seen_subcommand_from unregister" \
    -a "(_nws_registered_ws)"
