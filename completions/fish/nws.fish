# fish completion for nws (Nix Workspace Root Manager).
# Auto-loaded from vendor_completions.d. Tracks `nws help`'s subcommand list:
# service register unregister list version help.
# register: filesystem path. unregister: registered workspace canonical paths
# from `nws list` when the daemon is reachable, plus native file completion as
# fallback when it is not.

function _nws_registered_ws
    # `nws list` prints only the paths, one per line. When the daemon is
    # unreachable it prints nothing on stdout (error goes to stderr), so this
    # emits nothing and fish's native file completion applies instead.
    # Empty list prints "OK 0"; keep only absolute paths.
    nws list 2>/dev/null | string match -r '^/.*'
end

# Token 1: subcommand names.
complete -c nws -f -n "__fish_use_subcommand" \
    -a "service register unregister list version help"

# register: filesystem path, plus overlay flags when the word starts with "--".
complete -c nws -f -n '__fish_seen_subcommand_from register; and string match -q -- "-*" (commandline -ct)' \
    -a "--overlay\tURL of an overlay flake --attr-path\tattribute path for the last --overlay --overlay-attr\toverlay attribute name --no-flake\tnon-flake overlay expression --nixpkgs\tnixpkgs URL --resolver\texternal resolver script --dev-shell-packages\tcomma-separated attrs for the managed devShell"
complete -c nws -f -n "__fish_seen_subcommand_from register" \
    -a "(__fish_complete_path)"

# unregister: registered names from `nws list`, plus native files as fallback
# (this line intentionally omits -f so file completion stays enabled).
complete -c nws -n "__fish_seen_subcommand_from unregister" \
    -a "(_nws_registered_ws)"
