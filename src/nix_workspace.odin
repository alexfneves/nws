package main

// nws — Nix Workspace Root Manager.
//
// A single binary with a long-running daemon mode (`nws service`) and three
// client commands (`register`/`unregister`/`list`) that talk to the daemon
// over a localhost TCP control socket.
//
// The daemon watches a set of Nix "workspace" folders with inotify, and when a
// repo subfolder appears or disappears it rewrites that workspace's
// `flake.nix` so cloned repos are pinned to `path:./<name>` and uncloned ones
// keep (or return to) their canonical GitHub URL. It serves the control socket
// on 127.0.0.1:<port> using a single-threaded, poll-multiplexed event loop.

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "nwscore:core"

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

// Workspace is one watched folder: its canonical absolute path and the
// inotify watch descriptor assigned on add.
Workspace :: struct {
	path: string,
	wd:   linux.Wd,
}

// Client is one accepted control-socket connection. Buffering is per-fd so a
// command that arrives in multiple TCP chunks is only dispatched once a full
// '\n' is present.
Client :: struct {
	sock:    net.TCP_Socket,
	fd:      linux.Fd,
	buf:     [dynamic]u8,
	revents: linux.Fd_Poll_Events,
	served:  bool,
	closed:  bool,
}

Daemon_State :: struct {
	inotify_fd:  linux.Fd,
	listen_sock: net.TCP_Socket,
	ws:          [dynamic]Workspace,
	// ws_cfgs holds the full per-workspace backend settings (overlay entries,
	// nixpkgs URL) keyed by canonical workspace path. Only overlay workspaces
	// are present today; flake workspaces round-trip as the legacy string form.
	ws_cfgs:     map[string]core.Workspace_Config,
	clients:     [dynamic]Client,
	config_path: string,
	port:        int,
	logging:     bool,
}

Add_Result :: enum {
	OK,
	Already_Registered,
	Not_Dir,
	Watch_Failed,
}

// The single non-recursive watch on a workspace root. NO .ONLYDIR: the same
// watch also covers edits to the root's own flake.nix file.
WATCH_MASK :: linux.Inotify_Event_Mask {
	.CLOSE_WRITE,
	.CREATE,
	.DELETE,
	.MOVED_TO,
	.MOVED_FROM,
	.ATTRIB,
}

// ---------------------------------------------------------------------------
// CLI dispatch
// ---------------------------------------------------------------------------

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		print_usage()
		return
	}

	switch args[0] {
	case "service":
		config_path_override := ""
		for i := 1; i < len(args); i += 1 {
			if strings.has_prefix(args[i], "--config-path=") {
				config_path_override = args[i][len("--config-path="):]
			} else if args[i] == "--config-path" && i + 1 < len(args) {
				config_path_override = args[i + 1]
			}
		}
		run_service(config_path_override)
	case "register":
		rest := args[1:]
		if len(rest) == 0 {
			rest = [](string){}
		}
		cmd_register(rest)
	case "unregister":
		arg := ""
		if len(args) > 1 {
			arg = args[1]
		}
		cmd_unregister(arg)
	case "list":
		cmd_list()
	case "help", "--help", "-h":
		print_usage()
	case:
		fmt.eprintln("nws: unknown command:", args[0])
		print_usage()
	}
}

print_usage :: proc() {
	fmt.println("nws — Nix Workspace Root Manager")
	fmt.println()
	fmt.println("Usage:")
	fmt.println(
		"  nws service [--config-path PATH]  run the daemon (watches workspaces, serves the control socket)",
	)
	fmt.println("  nws register [PATH]     add a workspace (default: current directory)")
	fmt.println("                          overlay options: --overlay URL --attr-path ATTR")
	fmt.println(
		"                          [--overlay-attr NAME] [--no-flake] [--nixpkgs URL] [--resolver PATH]",
	)
	fmt.println("  nws unregister [PATH]   remove a workspace")
	fmt.println("  nws list                list registered workspaces")
	fmt.println("  nws help                show this help")
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

config_path :: proc() -> string {
	home, err := os.user_home_dir(context.allocator)
	if err != nil {
		return ""
	}
	defer delete(home)
	return strings.concatenate({home, "/.config/nws/config.json"}, context.allocator)
}

// normalize_path returns the lexically-cleaned absolute path for p, so that
// equivalent inputs (redundant slashes, "."/".." segments, a trailing slash)
// dedup consistently. Note: symlink resolution (realpath) is unavailable in
// this Odin, so symlink aliases are not collapsed here.
normalize_path :: proc(p: string) -> string {
	abs_p, perr := filepath.abs(p, context.allocator)
	if perr != nil {
		// Fall back to the raw input if we cannot resolve the cwd.
		cleaned, cerr := filepath.clean(p, context.allocator)
		if cerr != nil {
			return strings.clone(p, context.allocator)
		}
		return cleaned
	}
	cleaned, cerr := filepath.clean(abs_p, context.allocator)
	if cerr != nil {
		return abs_p
	}
	delete(abs_p)
	return cleaned
}

// resolve_path returns the canonical path a client command should act on:
// the given argument, or the current directory when no argument is supplied.
resolve_path :: proc(arg: string) -> string {
	if arg == "" {
		cwd, _ := os.get_working_directory(context.allocator)
		return cwd
	}
	return normalize_path(arg)
}

// ---------------------------------------------------------------------------
// Client commands (register / unregister / list)
// ---------------------------------------------------------------------------

client_port :: proc() -> int {
	cfg, _ := core.load_config(config_path())
	defer core.delete_workspaces(&cfg)
	return cfg.port
}

// tcp_request sends one line to the daemon and reads the full reply, following
// the connection-per-request protocol: the daemon replies then closes, so we
// read until EOF.
tcp_request :: proc(port: int, line: string) -> (ok: bool, data: string) {
	ep_str := strings.concatenate({"127.0.0.1:", fmt.tprintf("%d", port)}, context.allocator)
	ep, eok := net.parse_endpoint(ep_str)
	delete(ep_str)
	if !eok {
		return false, ""
	}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return false, ""
	}
	defer net.close(sock)

	_, _ = net.send_tcp(sock, transmute([]byte)line)

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	buf: [4096]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n <= 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
		if rerr != nil {
			break
		}
	}

	if strings.builder_len(b) == 0 {
		return false, ""
	}
	return true, strings.clone(strings.to_string(b), context.allocator)
}

// register_options holds the parsed CLI flags of `nws register`.
Register_Options :: struct {
	path:     string,
	overlays: [dynamic]core.Overlay_Entry,
	nixpkgs:  string,
	resolver: string,
}

cmd_register :: proc(argv: []string) {
	opts, ok := parse_register_flags(argv)
	if !ok {
		return // parse_register_flags already printed the error
	}
	defer delete(opts.overlays)

	port := client_port()
	path := resolve_path(opts.path)
	defer delete(path)

	// req borrows path/opts strings; register_encode only reads them.
	req: core.Register_Request = core.Register_Request {
		path        = path,
		nixpkgs_url = opts.nixpkgs,
		resolver    = opts.resolver,
	}
	if len(opts.overlays) > 0 {
		req.is_overlay = true
		req.overlays = opts.overlays
	}
	enc := core.register_encode(&req)
	defer delete(enc)
	line := strings.concatenate({"REGISTER ", enc, "\n"}, context.allocator)
	defer delete(line)

	sent, reply := tcp_request(port, line)
	if !sent {
		fmt.println("nws: cannot reach daemon on 127.0.0.1:", port, "- is the daemon running?")
		return
	}
	defer delete(reply)
	fmt.println(strings.trim_space(reply))
}

// parse_register_flags parses the argument vector of `nws register`. Flags:
// --overlay URL (repeatable), --attr-path ATTR (pairs with the preceding
// --overlay), --overlay-attr NAME and --no-flake (apply to the latest
// overlay), --nixpkgs URL, plus at most one positional PATH. On a usage
// error it prints a message to stderr and returns ok=false.
parse_register_flags :: proc(argv: []string) -> (opts: Register_Options, ok: bool) {
	fail :: proc(msg: string) {
		fmt.eprintln("nws register:", msg)
		fmt.eprintln(
			"usage: nws register [PATH] [--overlay URL --attr-path ATTR ...] [--overlay-attr NAME] [--no-flake] [--nixpkgs URL] [--resolver PATH]",
		)
	}

	i := 0
	for i < len(argv) {
		a := argv[i]
		switch a {
		case "--overlay":
			if i + 1 >= len(argv) {
				fail("--overlay requires a URL")
				return opts, false
			}
			append(&opts.overlays, core.Overlay_Entry{url = argv[i + 1], is_flake = true})
			i += 2
		case "--attr-path":
			if i + 1 >= len(argv) {
				fail("--attr-path requires a value")
				return opts, false
			}
			if len(opts.overlays) == 0 {
				fail("--attr-path without a preceding --overlay")
				return opts, false
			}
			opts.overlays[len(opts.overlays) - 1].attr_path = argv[i + 1]
			i += 2
		case "--overlay-attr":
			if i + 1 >= len(argv) {
				fail("--overlay-attr requires a name")
				return opts, false
			}
			if len(opts.overlays) == 0 {
				fail("--overlay-attr without a preceding --overlay")
				return opts, false
			}
			opts.overlays[len(opts.overlays) - 1].overlay_attr = argv[i + 1]
			i += 2
		case "--no-flake":
			if len(opts.overlays) == 0 {
				fail("--no-flake without a preceding --overlay")
				return opts, false
			}
			opts.overlays[len(opts.overlays) - 1].is_flake = false
			i += 1
		case "--nixpkgs":
			if i + 1 >= len(argv) {
				fail("--nixpkgs requires a URL")
				return opts, false
			}
			opts.nixpkgs = argv[i + 1]
			i += 2
		case "--resolver":
			if i + 1 >= len(argv) {
				fail("--resolver requires a path")
				return opts, false
			}
			opts.resolver = argv[i + 1]
			i += 2
		case:
			if strings.has_prefix(a, "--") {
				fmt.eprintln("nws register: unknown flag:", a)
				return opts, false
			}
			if opts.path != "" {
				fail("multiple PATH arguments given")
				return opts, false
			}
			opts.path = a
			i += 1
		}
	}

	if len(opts.overlays) > 0 {
		for ov, idx in opts.overlays {
			if ov.attr_path == "" {
				fail(fmt.tprintf("--overlay %q is missing its paired --attr-path", ov.url))
				return opts, false
			}
			_ = idx
		}
	}

	return opts, true
}

cmd_unregister :: proc(arg: string) {
	port := client_port()
	path := resolve_path(arg)
	enc := core.encode(path)
	defer {
		delete(enc)
		delete(path)
	}
	line := strings.concatenate({"UNREGISTER ", enc, "\n"}, context.allocator)
	defer delete(line)

	ok, reply := tcp_request(port, line)
	if !ok {
		fmt.println("nws: cannot reach daemon on 127.0.0.1:", port, "- is the daemon running?")
		return
	}
	defer delete(reply)
	fmt.println(strings.trim_space(reply))
}

cmd_list :: proc() {
	port := client_port()
	ok, data := tcp_request(port, "LIST\n")
	if !ok {
		fmt.println("nws: cannot reach daemon on 127.0.0.1:", port, "- is the daemon running?")
		return
	}
	defer delete(data)

	s := strings.trim_space(data)
	first_nl := strings.index_byte(s, '\n')
	if first_nl < 0 {
		fmt.println(strings.trim_space(s))
		return
	}
	header := s[:first_nl]
	if !strings.has_prefix(header, "OK") {
		fmt.println(strings.trim_space(header))
		return
	}
	rest := s[first_nl + 1:]
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := rest
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		if len(strings.trim_space(line)) > 0 {
			fmt.println(line)
		}
	}
}

// ---------------------------------------------------------------------------
// Daemon
// ---------------------------------------------------------------------------

should_log :: proc() -> bool {
	v := os.get_env_alloc("NWS_LOG", context.allocator)
	defer delete(v)
	return v != "0"
}

log_line :: proc(logging: bool, f: string, args: ..any) {
	if !logging {
		return
	}
	fmt.eprintf("nws: ")
	fmt.eprintf(f, ..args)
	fmt.eprintf("\n")
}

run_service :: proc(config_path_override: string = "") {
	logging := should_log()
	cfg_path := config_path_override
	if cfg_path == "" {
		cfg_path = config_path()
	}
	if len(cfg_path) == 0 {
		fmt.eprintln("nws: cannot determine home directory for config")
		return
	}
	cfg, _ := core.load_config(cfg_path)
	log_line(logging, "daemon starting on 127.0.0.1:%d", cfg.port)

	state := Daemon_State{}
	state.ws_cfgs = make(map[string]core.Workspace_Config)
	state.config_path = cfg_path
	state.port = cfg.port
	state.logging = logging

	// inotify
	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != nil {
		fmt.eprintln("nws: inotify_init1 failed:", errno)
		return
	}
	state.inotify_fd = fd

	// control listen socket
	ep_str := strings.concatenate({"127.0.0.1:", fmt.tprintf("%d", cfg.port)}, context.allocator)
	ep, eok := net.parse_endpoint(ep_str)
	delete(ep_str)
	if !eok {
		fmt.eprintln("nws: bad listen endpoint 127.0.0.1:", cfg.port)
		return
	}
	sock, lerr := net.listen_tcp(ep)
	if lerr != nil {
		fmt.eprintln("nws: listen_tcp failed:", lerr)
		return
	}
	if eb := net.set_blocking(sock, false); eb != nil {
		fmt.eprintln("nws: set_blocking(listen) failed:", eb)
	}
	state.listen_sock = sock
	log_line(logging, "listening on 127.0.0.1:%d", cfg.port)

	// Keep overlay workspaces' backend settings so save_state_config can
	// round-trip them instead of degrading to the legacy string form.
	for ws in cfg.workspaces {
		if ws.kind == .overlay {
			key := strings.clone(ws.name)
			state.ws_cfgs[key] = core.clone_workspace_config(ws)
		}
	}

	// Re-establish all configured workspaces (initial sync materialises an
	// already-present clone immediately, without waiting for an event).
	for ws in cfg.workspaces {
		#partial switch add_workspace(&state, ws.name, nil) {
		case .Not_Dir:
			log_line(
				logging,
				"warning: configured workspace %q is not a directory — skipping",
				ws.name,
			)
		case .Watch_Failed:
			log_line(logging, "warning: cannot watch %q — skipping", ws.name)
		}
	}
	core.delete_workspaces(&cfg)
	log_line(logging, "%d workspace(s) loaded", len(state.ws))

	// Main event loop: inotify fd, listen fd, then one poll entry per client.
	for {
		poll_fds := build_poll(&state)
		n, perr := linux.poll(poll_fds[:], -1)
		if perr != nil || n <= 0 {
			delete(poll_fds)
			continue
		}
		for i in 0 ..< len(state.clients) {
			state.clients[i].revents = poll_fds[2 + i].revents
		}
		if len(poll_fds) > 0 && poll_fds[0].revents != {} {
			drain_inotify(&state, logging)
		}
		if len(poll_fds) > 1 && poll_fds[1].revents != {} {
			accept_clients(&state, logging)
		}
		service_clients(&state, logging)
		delete(poll_fds)
	}
}

build_poll :: proc(state: ^Daemon_State) -> [dynamic]linux.Poll_Fd {
	fds := make([dynamic]linux.Poll_Fd)
	append(&fds, linux.Poll_Fd{fd = state.inotify_fd, events = {.IN}})
	append(&fds, linux.Poll_Fd{fd = tcp_fd(state.listen_sock), events = {.IN}})
	for c in state.clients {
		append(&fds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
	}
	return fds
}

// tcp_fd unwraps a TCP_Socket (distinct Socket :: distinct i64) to the 32-bit
// linux.Fd used for poll. Real fds fit in 32 bits, so the truncating cast is
// safe.
tcp_fd :: proc(sock: net.TCP_Socket) -> linux.Fd {
	return linux.Fd(transmute(i64)sock)
}

accept_clients :: proc(state: ^Daemon_State, logging: bool) {
	for {
		client, _, aerr := net.accept_tcp(state.listen_sock)
		if aerr != nil {
			break // would-block (non-blocking listen) — no more pending
		}
		if eb := net.set_blocking(client, false); eb != nil {
			log_line(logging, "set_blocking(client) failed: %v", eb)
		}
		append(&state.clients, Client{sock = client, fd = tcp_fd(client), buf = make([dynamic]u8)})
		log_line(logging, "client connected (fd %d)", tcp_fd(client))
	}
}

service_clients :: proc(state: ^Daemon_State, logging: bool) {
	for i := 0; i < len(state.clients); {
		c := &state.clients[i]

		if .HUP in c.revents || .ERR in c.revents {
			c.closed = true
		}
		if .IN in c.revents || c.closed {
			buf: [4096]u8
			for {
				n, rerr := net.recv_tcp(c.sock, buf[:])
				if n > 0 {
					append(&c.buf, ..buf[:n])
					continue
				}
				// n == 0 here: keep the client on Would_Block (more data may
				// come on a later poll pass); close only on real EOF or error.
				if rerr == .Would_Block {
					break
				}
				c.closed = true // graceful EOF (0, nil) or a real error
				break
			}
		}

		data := string(c.buf[:])
		if nl := strings.index_byte(data, '\n'); nl >= 0 {
			line := strings.trim_space(data[:nl])
			reply := route_command(state, line)
			net.send_tcp(c.sock, transmute([]byte)reply)
			delete(reply)
			log_line(logging, "served %q", line)
			c.served = true
		}

		if c.served || c.closed {
			log_line(logging, "closing client (fd %d)", c.fd)
			close_client(state, i)
			continue
		}
		i += 1
	}
}

close_client :: proc(state: ^Daemon_State, idx: int) {
	c := &state.clients[idx]
	net.close(c.sock)
	delete(c.buf)
	unordered_remove(&state.clients, idx)
}

// ---------------------------------------------------------------------------
// Control protocol routing
// ---------------------------------------------------------------------------

route_command :: proc(state: ^Daemon_State, line: string) -> string {
	sp := strings.index_byte(line, ' ')
	verb := line
	rest := ""
	if sp >= 0 {
		verb = line[:sp]
		rest = strings.trim_space(line[sp + 1:])
	}

	switch verb {
	case "REGISTER":
		req, pok := core.register_parse(rest)
		if !pok {
			return strings.clone(
				"ERROR bad REGISTER request (bad escape, unsupported backend, or incomplete --overlay/--attr-path pairing)\n",
				context.allocator,
			)
		}
		defer core.register_free(&req)
		norm := normalize_path(req.path)
		defer delete(norm)

		// Overlay request → build the full backend config so it lands in
		// ws_cfgs and survives save_state_config. Legacy request → nil (flake).
		// NOTE: freed via a CASE-LEVEL conditional defer — a defer inside the
		// if-block below would fire before add_workspace consumes the config.
		wscfg: core.Workspace_Config
		have_cfg := false
		defer if have_cfg {
			core.delete_workspace_config(wscfg)
		}
		if req.is_overlay {
			wscfg = core.Workspace_Config {
				name        = strings.clone(norm),
				kind        = .overlay,
				nixpkgs_url = req.nixpkgs_url != "" ? strings.clone(req.nixpkgs_url) : "",
				resolver    = req.resolver != "" ? strings.clone(req.resolver) : "",
			}
			wscfg.overlays = make([dynamic]core.Overlay_Entry, 0, len(req.overlays))
			for ov in req.overlays {
				append(
					&wscfg.overlays,
					core.Overlay_Entry {
						url = strings.clone(ov.url),
						attr_path = strings.clone(ov.attr_path),
						overlay_attr = ov.overlay_attr != "" ? strings.clone(ov.overlay_attr) : "",
						is_flake = ov.is_flake,
					},
				)
			}
			have_cfg = true
		}
		cfg_ptr: ^core.Workspace_Config
		if have_cfg {
			cfg_ptr = &wscfg
		}
		switch add_workspace(state, norm, cfg_ptr) {
		case .OK:
			return strings.clone("OK\n", context.allocator)
		case .Already_Registered:
			return strings.clone("ERROR already registered\n", context.allocator)
		case .Not_Dir:
			return strings.clone("ERROR not a directory\n", context.allocator)
		case .Watch_Failed:
			return strings.clone("ERROR watch failed\n", context.allocator)
		}

	case "UNREGISTER":
		dec, ok := core.decode(rest)
		if !ok {
			return strings.clone("ERROR bad path encoding\n", context.allocator)
		}
		defer delete(dec)
		norm := normalize_path(dec)
		defer delete(norm)
		if remove_workspace(state, norm) {
			return strings.clone("OK\n", context.allocator)
		}
		return strings.clone("ERROR not registered\n", context.allocator)

	case "LIST":
		return list_reply(state)

	case:
		return strings.clone("ERROR unknown command\n", context.allocator)
	}
	return strings.clone("ERROR\n", context.allocator)
}

list_reply :: proc(state: ^Daemon_State) -> string {
	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "OK %d\n", len(state.ws))
	for ws in state.ws {
		fmt.sbprintf(&b, "%s\n", ws.path)
	}
	return strings.clone(strings.to_string(b), context.allocator)
}

// ---------------------------------------------------------------------------
// Workspace management
// ---------------------------------------------------------------------------

add_workspace :: proc(
	state: ^Daemon_State,
	path: string,
	wscfg: ^core.Workspace_Config,
) -> Add_Result {
	if !os.is_dir(path) {
		return .Not_Dir
	}
	if has_workspace(state, path) {
		return .Already_Registered
	}

	cs := strings.clone_to_cstring(path)
	defer delete(cs)
	wd, werr := linux.inotify_add_watch(state.inotify_fd, cs, WATCH_MASK)
	if werr != nil {
		return .Watch_Failed
	}

	if wscfg != nil {
		key := strings.clone(path)
		state.ws_cfgs[key] = core.clone_workspace_config(wscfg^)
	}

	append(&state.ws, Workspace{path = strings.clone(path), wd = wd})
	log_line(state.logging, "added workspace %q (wd %d)", path, wd)

	// Materialise an already-present clone immediately, then persist.
	sync_workspace(state, path)
	save_state_config(state)
	return .OK
}

remove_workspace :: proc(state: ^Daemon_State, path: string) -> bool {
	for ws, i in state.ws {
		if ws.path == path {
			linux.inotify_rm_watch(state.inotify_fd, ws.wd)
			forget_workspace_config(state, path)
			log_line(state.logging, "removed workspace %q (wd %d)", ws.path, ws.wd)
			delete(ws.path)
			unordered_remove(&state.ws, i)
			save_state_config(state)
			return true
		}
	}
	return false
}

has_workspace :: proc(state: ^Daemon_State, path: string) -> bool {
	for ws in state.ws {
		if ws.path == path {
			return true
		}
	}
	return false
}

workspace_path_for_wd :: proc(state: ^Daemon_State, wd: linux.Wd) -> string {
	for ws in state.ws {
		if ws.wd == wd {
			return ws.path
		}
	}
	return ""
}

// drop_workspace_wd removes the workspace whose watch fires wd (the root was
// deleted or the watch was auto-removed) and persists the config.
drop_workspace_wd :: proc(state: ^Daemon_State, wd: linux.Wd) {
	for ws, i in state.ws {
		if ws.wd == wd {
			linux.inotify_rm_watch(state.inotify_fd, wd)
			forget_workspace_config(state, ws.path)
			delete(ws.path)
			unordered_remove(&state.ws, i)
			save_state_config(state)
			return
		}
	}
}

// forget_workspace_config frees and removes any stored backend settings for a
// path. Missing paths are a no-op (flake workspaces have none).
forget_workspace_config :: proc(state: ^Daemon_State, path: string) {
	if cfg, ok := state.ws_cfgs[path]; ok {
		core.delete_workspace_config(cfg)
		// The map key is a distinct cloned buffer (strings.clone at insert);
		// never delete the caller-owned `path`. Find and free the real key.
		for k in state.ws_cfgs {
			if k == path {
				delete_key(&state.ws_cfgs, k)
				delete(k)
				break
			}
		}
	}
}

save_state_config :: proc(state: ^Daemon_State) {
	cfg := core.Config {
		port = state.port,
	}
	cfg.workspaces = make([dynamic]core.Workspace_Config, context.allocator)
	defer core.delete_workspaces(&cfg)
	for ws in state.ws {
		if saved, ok := state.ws_cfgs[ws.path]; ok {
			// Overlay (and other non-default) backends: persist the full
			// object form so backend settings survive the register→config
			// round-trip.
			append(&cfg.workspaces, core.clone_workspace_config(saved))
		} else {
			append(&cfg.workspaces, core.Workspace_Config{name = strings.clone(ws.path)})
		}
	}
	core.save_config(state.config_path, cfg)
}

// ---------------------------------------------------------------------------
// inotify event handling
// ---------------------------------------------------------------------------

drain_inotify :: proc(state: ^Daemon_State, logging: bool) {
	buf: [4096]u8
	for {
		n, errno := linux.read(state.inotify_fd, buf[:])
		if errno != nil || n <= 0 {
			break // EAGAIN — queue drained
		}
		offset := 0
		for offset < n {
			ev := (^linux.Inotify_Event)(raw_data(buf[offset:]))
			process_inotify_event(state, ev, logging)
			offset += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
}

process_inotify_event :: proc(state: ^Daemon_State, ev: ^linux.Inotify_Event, logging: bool) {
	mask := ev.mask
	wd := ev.wd

	if .Q_OVERFLOW in mask {
		log_line(logging, "IN_Q_OVERFLOW — rescanning all workspaces")
		for ws in state.ws {
			sync_workspace(state, ws.path)
		}
		return
	}

	if .IGNORED in mask {
		log_line(logging, "watch ignored (wd %d) — dropping", wd)
		drop_workspace_wd(state, wd)
		return
	}

	if .DELETE_SELF in mask || .MOVE_SELF in mask {
		p := workspace_path_for_wd(state, wd)
		if p != "" && !os.exists(p) {
			log_line(logging, "workspace %q deleted — dropping", p)
			drop_workspace_wd(state, wd)
		} else if p != "" {
			sync_workspace(state, p)
		}
		return
	}

	if (.CREATE in mask) ||
	   (.DELETE in mask) ||
	   (.MOVED_TO in mask) ||
	   (.MOVED_FROM in mask) ||
	   (.CLOSE_WRITE in mask) ||
	   (.ATTRIB in mask) {
		p := workspace_path_for_wd(state, wd)
		if p != "" {
			log_line(logging, "fs event on %q (mask %v)", p, mask)
			sync_workspace(state, p)
		}
	}
}

// ---------------------------------------------------------------------------
// Root flake generation & sync
// ---------------------------------------------------------------------------

// state_path resolves the persisted canonical-URL state file location:
// alongside the config file (e.g. ~/.config/nws/state.json), honouring any
// --config-path override's directory.
state_path :: proc(state: ^Daemon_State) -> string {
	return strings.concatenate({filepath.dir(state.config_path), "/state.json"}, context.allocator)
}

// atomic_write writes text to path via a temp file + rename in the same
// directory, so readers never observe a partial file.
atomic_write :: proc(path, text: string, logging: bool, what: string) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.allocator)
	defer delete(tmp)
	if err := os.write_entire_file(tmp, text); err != nil {
		os.remove(tmp)
		log_line(logging, "failed to write %s: %v", tmp, err)
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		log_line(logging, "failed to rename %s: %v", tmp, err)
		return false
	}
	log_line(logging, "%s %s", what, path)
	return true
}

// sync_workspace regenerates the workspace ROOT flake.nix from the current
// set of first-level children. Children are never modified: their flakes are
// only read (via their .git/config for the canonical URL). Write policy:
//
//   - no root flake        → create a minimal file wrapping the generated block
//   - root with nws block  → the marked region is replaced; user bytes outside
//     the markers are never touched
//   - user-authored root   → the block is injected before the final closing `}`;
//     a flake that already declares its own top-level inputs/outputs is left
//     alone (injecting the block would duplicate them)
//   - unparseable root     → log and never touch
//   - patched bytes equal  → skip the write (no self-trigger loop)
sync_workspace :: proc(state: ^Daemon_State, path: string) {
	// Backend dispatch: overlay workspaces take a completely separate pipeline
	// (no state.json, no .git probing, no sibling deps).
	if cfg, ok := state.ws_cfgs[path]; ok && cfg.kind == .overlay {
		sync_workspace_overlay(state, path, cfg)
		return
	}

	fl_path := strings.concatenate({path, "/flake.nix"}, context.allocator)
	defer delete(fl_path)

	sp := state_path(state)
	defer delete(sp)
	st, _ := core.load_state(sp)
	defer core.destroy_state(&st)

	local := local_repos(path)
	defer {
		for r in local {
			delete(r)
		}
		delete(local)
	}

	children := make([dynamic]core.Child_Info, 0, len(local))
	defer {
		for c in children {
			if c.has_url {
				delete(c.url)
			}
			for d in c.deps {
				delete(d)
			}
			if len(c.deps) > 0 {
				delete(c.deps)
			}
		}
		delete(children)
	}

	state_dirty := false
	for name in local {
		child := core.Child_Info {
			name = name,
		} // borrows local[i]; freed above

		// strings.concatenate (heap) so we can delete it; fmt.tprintf uses
		// the temporary allocator and must never be freed manually.
		child_dir := strings.concatenate({path, "/", name}, context.allocator)
		url, ok := core.read_origin_url(child_dir)

		// While the clone is present, parse its flake.nix input names so the
		// generator can wire sibling dependencies locally. Absent clones keep
		// no deps (their GitHub URL needs no local wiring).
		if ok {
			child_flake := strings.concatenate({child_dir, "/flake.nix"}, context.allocator)
			if text, rerr := os.read_entire_file(child_flake, context.allocator); rerr == nil {
				child.deps = core.parse_flake_input_names(string(text))
				delete(text)
			}
			delete(child_flake)
		}
		delete(child_dir)

		if ok {
			child.url = url
			child.has_url = true
			stored, has := core.lookup_url(&st, path, name)
			if !has || stored != url {
				core.upsert_url(&st, path, name, url)
				state_dirty = true
			}
		} else if stored, has := core.lookup_url(&st, path, name); has {
			child.url = strings.clone(stored)
			child.has_url = true
		}
		append(&children, child)
	}

	// Children recorded in state but whose clone is currently absent: emit
	// them pinned at their persisted canonical URL so a removed repo restores
	// to its GitHub URL instead of silently vanishing from the root flake.
	if repos, has_ws := st.workspaces[path]; has_ws {
		for name, url in repos {
			found := false
			for c in children {
				if c.name == name {
					found = true
					break
				}
			}
			if found {
				continue
			}
			append(
				&children,
				core.Child_Info {
					// `name` borrows the state map key (state outlives these
					// children); `url` is cloned because the children cleanup
					// deletes it.
					name    = name,
					url     = strings.clone(url),
					has_url = true,
				},
			)
		}
	}

	// Opportunistically prune state entries for workspaces that are no longer
	// registered (deleted or unregistered since they were written).
	stale := make([dynamic]string, 0, len(st.workspaces))
	defer {
		for p in stale {
			delete(p)
		}
		delete(stale)
	}
	for ws_path in st.workspaces {
		if !has_workspace(state, ws_path) {
			append(&stale, strings.clone(ws_path))
		}
	}
	for p in stale {
		if core.prune_workspace(&st, p) {
			state_dirty = true
		}
	}

	defer {
		if state_dirty {
			if !core.save_state(sp, &st) {
				log_line(state.logging, "failed to save state %s", sp)
			}
		}
	}

	block := core.generate_root_block(children[:])
	defer delete(block)

	existing, rerr := os.read_entire_file(fl_path, context.allocator)
	if rerr != nil {
		// No root flake yet: create a minimal file wrapping the block.
		new_text, ok := core.patch_flake("", block)
		if ok && len(new_text) > 0 {
			atomic_write(fl_path, new_text, state.logging, "generated")
		}
		delete(new_text)
		return
	}
	defer delete(existing)

	new_text, ok := core.patch_flake(string(existing), block)
	if !ok {
		log_line(state.logging, "leaving flake alone (no safe injection point): %s", fl_path)
		return
	}
	defer delete(new_text)

	if string(existing) == new_text {
		return // loop guard on PATCHED result
	}
	atomic_write(fl_path, new_text, state.logging, "regenerated")
}

// ---------------------------------------------------------------------------
// Overlay backend
// ---------------------------------------------------------------------------

// sync_workspace_overlay regenerates an overlay workspace's root flake.nix:
// the recursive built-in scan (core.scan_overlay_children) and the optional
// external resolver subprocess (core.run_resolver) both produce
// Overlay_Child sets; core.merge_children unions/dedups them (resolver wins
// on same-name/different-rel_path collisions — logged), and
// core.generate_overlay_block splices the result under the shared write
// policy (create-or-patch + patched-byte skip). Overlay discovery is purely
// scan+resolver: no `nix eval` shell-out remains (ISC-A-1). Both producers
// are fail-open — an unreadable scan dir, a depth/count cap, a failing
// resolver or a malformed resolver line never prevents a regenerated managed
// flake. It deliberately skips state.json and .git/config — neither applies
// to overlay mode.
sync_workspace_overlay :: proc(state: ^Daemon_State, path: string, cfg: core.Workspace_Config) {
	fl_path := strings.concatenate({path, "/flake.nix"}, context.allocator)
	defer delete(fl_path)

	// Built-in producer: recursive directory scan (no subprocess). Hidden
	// dirs (.git, .nws) are never children; depth/count caps warn first.
	builtin, scan_warn := core.scan_overlay_children(read_dir_adapter, path)
	defer core.free_resolver_children(builtin)
	defer delete(scan_warn)
	if len(scan_warn) > 0 {
		log_line(state.logging, "warning: %s", scan_warn)
	}

	// Optional resolver producer: one inline subprocess per sync emitting
	// NAME\tRELPATH lines. Non-zero exit / spawn error fails open — splice
	// nothing from it, keep the built-in scan's children.
	res := ([]core.Overlay_Child)(nil)
	if cfg.resolver != "" {
		rchildren, rok := core.run_resolver(cfg.resolver, path)
		if !rok {
			log_line(
				state.logging,
				"warning: resolver %q failed — splicing none of its output",
				cfg.resolver,
			)
		}
		res = rchildren
	}
	defer core.free_resolver_children(res)

	// Union/dedup/sort: resolver wins on same-name/different-rel_path
	// collisions (duplicate Nix attr keys would hard-break eval) — warned.
	matched, merge_warn := core.merge_children(builtin, res)
	defer core.free_resolver_children(matched)
	defer delete(merge_warn)
	if len(merge_warn) > 0 {
		log_line(state.logging, "warning: %s", merge_warn)
	}

	block := core.generate_overlay_block(matched, cfg)
	defer delete(block)

	// Shared write policy (same as the flake backend): create-or-patch + byte-skip.
	existing, rerr := os.read_entire_file(fl_path, context.allocator)
	if rerr != nil {
		// No root flake yet: create a minimal file wrapping the block.
		new_text, ok := core.patch_flake("", block)
		if ok && len(new_text) > 0 {
			atomic_write(fl_path, new_text, state.logging, "generated")
		}
		delete(new_text)
		return
	}
	defer delete(existing)

	new_text, ok := core.patch_flake(string(existing), block)
	if !ok {
		log_line(state.logging, "leaving flake alone (no safe injection point): %s", fl_path)
		return
	}
	defer delete(new_text)

	if string(existing) == new_text {
		return // loop guard on PATCHED result
	}
	atomic_write(fl_path, new_text, state.logging, "regenerated")
}

// read_dir_adapter wires the scanner's Dir_Listing_Proc seam to the real
// filesystem: it lists `dir` with os.read_directory_by_path and converts the
// results into core.Dir_Entry values. `name` strings are cloned into the
// passed allocator — the scanner owns and frees them. Unreadable directories
// fail open (ok = false, treated as an empty listing by the scanner).
read_dir_adapter :: proc(dir: string, allocator: mem.Allocator) -> ([]core.Dir_Entry, bool) {
	fis, derr := os.read_directory_by_path(dir, -1, allocator)
	if derr != nil {
		return nil, false
	}
	defer os.file_info_slice_delete(fis, allocator)
	entries := make([]core.Dir_Entry, len(fis), allocator)
	for fi, i in fis {
		entries[i] = core.Dir_Entry {
			name   = strings.clone(fi.name, allocator),
			is_dir = fi.type == .Directory,
		}
	}
	return entries, true
}

// local_repos returns the first-level subfolders of path that look like local
// clones: they contain a .git directory or their own flake.nix.
local_repos :: proc(path: string) -> [dynamic]string {
	res := make([dynamic]string)
	fis, derr := os.read_directory_by_path(path, -1, context.allocator)
	if derr != nil {
		return res
	}
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if fi.type != .Directory {
			continue
		}
		// Hidden directories are never local clones.
		if strings.has_prefix(fi.name, ".") {
			continue
		}
		git := strings.concatenate({fi.fullpath, "/.git"}, context.allocator)
		own_flake := strings.concatenate({fi.fullpath, "/flake.nix"}, context.allocator)
		defer {
			delete(git)
			delete(own_flake)
		}
		if os.exists(git) || os.exists(own_flake) {
			append(&res, strings.clone(fi.name, context.allocator))
		}
	}
	return res
}
