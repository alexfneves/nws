# Code Review

**Reviewed:** `nws` implementation (commits 464666f, b129b59, 6bff4f3) against `.pi/plans/2026-08-11-nws/plan.md` (rev 2).
**Verdict:** NEEDS CHANGES (one P1 to fix before merge; everything else is solid)

## Summary

The implementation is high quality and matches the plan's intent on nearly every point. I verified it
by building (`odin build ... -file -collection:nwscore=src`), running all 12 unit tests (`odin test
tests -collection:nwscore=src` — all pass), and live-testing the daemon end-to-end (register, initial
sync, space-path handling, duplicate rejection, clone-remove restore, root-deletion drop, restart
persistence). One real bug remains in the non-blocking TCP read path: it treats a `Would_Block` return
as EOF and closes the client mid-command, which defeats the plan's own per-fd multi-chunk buffering
requirement (§9 item 3) and the README's stated guarantee. This was reproduced (split a command across
two TCP segments → daemon closed the connection without a reply).

## Findings

### [P1] Non-blocking recv loop treats `.Would_Block` as EOF, dropping split commands
**File:** `src/nix_workspace.odin:431-437` (inside `service_clients`)

**Issue:** The read loop is:
```odin
for {
    n, rerr := net.recv_tcp(c.sock, buf[:])
    if n > 0 { append(&c.buf, ..buf[:n]) }
    if rerr != nil || n <= 0 {
        c.closed = true
        break
    }
}
```
On a non-blocking socket, `recv_tcp` returns `(0, net.TCP_Recv_Error.Would_Block)` (errno `EAGAIN`)
when there is simply no more data **right now** — verified in `share/core/net/socket_linux.odin`
(`_recv_tcp` returns `_tcp_recv_error(.EAGAIN)` → `.Would_Block`). Because `n <= 0` here covers
`Would_Block`, the client is marked `closed` and dropped as soon as the available bytes don't contain a
full `\n`. Any command split across TCP segments (larger paths, Nagle/delayed-ACK interleaving) is
silently discarded.

This contradicts the plan's explicit, post-review must-have (§2 "Per-fd read buffering ... a command is
dispatched only after a full `\n` is present (handles partial-line / multi-chunk arrivals)", §9 item 3)
and the README's claim that partial/multi-chunk commands are buffered until `\n`.

**Reproduced:** sent `REGISTER /tmp/`, slept 0.5s, then sent the rest `ws_multi\n` on one connection.
Daemon replied with nothing and logged `client connected (fd 5)` → `closing client (fd 5)` with no
`served` line. In the single-segment case it works only because the serve block runs *before* the
`c.served || c.closed` check — the would-be-block close is masked. The bug surfaces specifically in the
partial-line case the design is supposed to handle.

**Suggested Fix:** break (without closing) on `Would_Block`; only set `closed` on a real EOF or error
(graceful EOF is `(0, nil)`; `Connection_Closed` is an error):
```odin
for {
    n, rerr := net.recv_tcp(c.sock, buf[:])
    if n > 0 { append(&c.buf, ..buf[:n]) }
    if rerr == .Would_Block { break }      // drained for now — wait for next poll
    if n <= 0 || rerr != nil {             // EOF or real error
        c.closed = true
        break
    }
}
```

### [P2] Canonicalisation doesn't resolve symlinks (`os.real_path` never called)
**File:** `src/nix_workspace.odin` — `normalize_path` (~line 138) and `add_workspace`

**Issue:** Plan §9 item 2 explicitly says "canonicalise (`os.real_path`), dedupe, reject duplicates".
The implementation only makes the path absolute and strips trailing slashes; `os.real_path` is never
called. Two symlink aliases of the same directory (e.g. register `~/proj` and `/real/path/proj`) won't be
deduped (second register adds a duplicate watch) and config stores the non-canonical spelling.

**Suggested Fix:** after `normalize_path`, call `os.real_path` and store/watch/dedupe against its result.

### [P3] `should_log()` re-reads `NWS_LOG` and allocates on every add/remove/rewrite
**File:** `src/nix_workspace.odin` — `should_log` / `log_line` call sites (`add_workspace`,
`remove_workspace`, `drop_workspace_wd`, `sync_workspace`)

**Issue:** `should_log()` calls `os.get_env_alloc("NWS_LOG")` every time it's invoked, so the environment
is read (and a string allocated/freed) on each watch change and each flake rewrite, and the result is
recomputed per call instead of being cached for the daemon's lifetime. Works correctly, but it's needless
churn in the event loop.

**Suggested Fix:** compute `logging := should_log()` once at daemon start and thread it through, or cache
it on `Daemon_State`.

## What's Good
- **Single-threaded poll loop, no threads** — matches plan §2. `poll_fds` is rebuilt each iteration from
  current clients, revents are copied before accept/service, and client removal via `unordered_remove` +
  the `continue` (reprocess-the-swapped-element) pattern in `service_clients` is correct — no stale poll
  entries, no double-close.
- **Variable-length inotify parse is correct** — advances by `size_of(linux.Inotify_Event) + ev.len` in a
  loop; `WATCH_MASK` has `IN_CLOSE_WRITE` and correctly omits `IN_ONLYDIR`. Verified live: CREATE /
  CLOSE_WRITE / DELETE / MOVED events all trigger a re-sync.
- **Overflow/removal recovery works** — `IN_Q_OVERFLOW` full-rescan, `IN_IGNORED`/`DELETE_SELF` drop +
  persist. Verified live: deleting a workspace root dropped the entry from `list` *and* rewrote
  `config.json` to empty, with no crash.
- **Initial sync** — `sync_workspace` runs immediately in `add_workspace` (register with a clone present
  materialises it at once) and for every workspace at daemon startup. Verified live.
- **Marker hygiene** — existing `# nws:` marker is reused, never duplicated (`extract_marker` +
  `has_marker`), and the transform is idempotent. Confirmed by the unit tests and by live remove-clone
  restore (`path:./repo-a` → canonical `github:...`, marker preserved).
- **Config safety** — atomic temp-file+rename, parent-dir auto-create, corrupt/missing file → defaults.
  Round-trip tests pass; live config JSON matches across daemon restarts.
- **Path handling** — percent-encoding round-trips spaces and `%`; duplicate register correctly returns
  `ERROR already registered`; space-containing workspace worked end-to-end (register → rewrite → list →
  unregister). (All verified live.)
- **Wiring/flake** — build (`-file -collection:nwscore=src`) and test (`odin test tests
  -collection:nwscore=src`) commands both pass; `systemdUnit` derivation is shipped by `main`; devenv
  `processes.nws` and README are accurate (with the single caveat of the multi-chunk claim fixed by the
  P1).
