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
import "core:net"
import "core:os"
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
	clients:     [dynamic]Client,
	config_path: string,
	port:        int,
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
		run_service()
	case "register":
		arg := ""
		if len(args) > 1 {
			arg = args[1]
		}
		cmd_register(arg)
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
		"  nws service             run the daemon (watches workspaces, serves the control socket)",
	)
	fmt.println("  nws register [PATH]     add a workspace (default: current directory)")
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

// normalize_path makes a path absolute (if it isn't) and strips trailing
// slashes, so the daemon stores canonical absolute paths for dedup + watches.
normalize_path :: proc(p: string) -> string {
	t := p
	for len(t) > 1 && t[len(t) - 1] == '/' {
		t = t[:len(t) - 1]
	}
	if strings.has_prefix(t, "/") {
		return strings.clone(t, context.allocator)
	}
	cwd, _ := os.get_working_directory(context.allocator)
	defer delete(cwd)
	return strings.concatenate({cwd, "/", t}, context.allocator)
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
	defer {
		for w in cfg.workspaces {
			delete(w)
		}
		delete(cfg.workspaces)
	}
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

cmd_register :: proc(arg: string) {
	port := client_port()
	path := resolve_path(arg)
	enc := core.encode(path)
	defer {
		delete(enc)
		delete(path)
	}
	line := strings.concatenate({"REGISTER ", enc, "\n"}, context.allocator)
	defer delete(line)

	ok, reply := tcp_request(port, line)
	if !ok {
		fmt.println("nws: cannot reach daemon on 127.0.0.1:", port, "- is the daemon running?")
		return
	}
	defer delete(reply)
	fmt.println(strings.trim_space(reply))
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

run_service :: proc() {
	logging := should_log()
	cfg_path := config_path()
	if len(cfg_path) == 0 {
		fmt.eprintln("nws: cannot determine home directory for config")
		return
	}
	cfg, _ := core.load_config(cfg_path)
	log_line(logging, "daemon starting on 127.0.0.1:%d", cfg.port)

	state := Daemon_State{}
	state.config_path = cfg_path
	state.port = cfg.port

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

	// Re-establish all configured workspaces (initial sync materialises an
	// already-present clone immediately, without waiting for an event).
	for ws in cfg.workspaces {
		#partial switch add_workspace(&state, ws) {
		case .Not_Dir:
			log_line(
				logging,
				"warning: configured workspace %q is not a directory — skipping",
				ws,
			)
		case .Watch_Failed:
			log_line(logging, "warning: cannot watch %q — skipping", ws)
		}
	}
	for w in cfg.workspaces {
		delete(w)
	}
	delete(cfg.workspaces)
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
				}
				if rerr != nil || n <= 0 {
					c.closed = true
					break
				}
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
		dec, ok := core.decode(rest)
		if !ok {
			return strings.clone("ERROR bad path encoding\n", context.allocator)
		}
		defer delete(dec)
		norm := normalize_path(dec)
		defer delete(norm)
		switch add_workspace(state, norm) {
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

add_workspace :: proc(state: ^Daemon_State, path: string) -> Add_Result {
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

	append(&state.ws, Workspace{path = strings.clone(path, context.allocator), wd = wd})
	log_line(should_log(), "added workspace %q (wd %d)", path, wd)

	// Materialise an already-present clone immediately, then persist.
	sync_workspace(state, path)
	save_state_config(state)
	return .OK
}

remove_workspace :: proc(state: ^Daemon_State, path: string) -> bool {
	for ws, i in state.ws {
		if ws.path == path {
			linux.inotify_rm_watch(state.inotify_fd, ws.wd)
			log_line(should_log(), "removed workspace %q (wd %d)", ws.path, ws.wd)
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
			delete(ws.path)
			unordered_remove(&state.ws, i)
			save_state_config(state)
			return
		}
	}
}

save_state_config :: proc(state: ^Daemon_State) {
	cfg := core.Config {
		port = state.port,
	}
	cfg.workspaces = make([dynamic]string, context.allocator)
	defer delete(cfg.workspaces)
	for ws in state.ws {
		append(&cfg.workspaces, ws.path)
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
// Flake sync
// ---------------------------------------------------------------------------

sync_workspace :: proc(state: ^Daemon_State, path: string) {
	flake := strings.concatenate({path, "/flake.nix"}, context.allocator)
	defer delete(flake)

	data, rerr := os.read_entire_file(flake, context.allocator)
	if rerr != nil {
		return // no flake.nix yet — nothing to do
	}
	defer delete(data)
	text := string(data)

	local := local_repos(path)
	defer {
		for r in local {
			delete(r)
		}
		delete(local)
	}

	new_text, changed := core.sync_flake(text, local[:])
	if !changed {
		delete(new_text)
		return
	}
	defer delete(new_text)

	tmp := strings.concatenate({flake, ".tmp"}, context.allocator)
	defer delete(tmp)
	if err := os.write_entire_file(tmp, new_text); err == nil {
		os.rename(tmp, flake)
		log_line(should_log(), "rewrote %s", flake)
	} else {
		os.remove(tmp)
		log_line(should_log(), "failed to write %s: %v", tmp, err)
	}
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
