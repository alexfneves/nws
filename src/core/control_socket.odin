package core

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// Control-socket path resolution, shared by the daemon (`nws service`) and the
// CLI client commands so both sides always agree on where the socket lives.

// SOCKET_PATH_MAX is the longest usable socket path in bytes: sockaddr_un's
// sun_path is 108 bytes and must also hold the terminating NUL.
SOCKET_PATH_MAX :: 107

// SOCKET_DIR_NAME / SOCKET_FILE_NAME make up the default location under the
// per-user runtime directory: $XDG_RUNTIME_DIR/nws/control.sock.
SOCKET_DIR_NAME :: "nws"
SOCKET_FILE_NAME :: "control.sock"

// resolve_socket_path picks the control-socket path from its inputs, in order:
//   1. env_socket (NWS_SOCKET) when non-empty
//   2. cfg_socket (config.json "socket") when non-empty
//   3. <xdg_runtime_dir>/nws/control.sock when xdg_runtime_dir is non-empty
//   4. /run/user/<uid>/nws/control.sock
// Pure: the caller supplies the environment. The result is always freshly
// allocated. Validate it with socket_path_error before use.
resolve_socket_path :: proc(
	env_socket, cfg_socket, xdg_runtime_dir: string,
	uid: u32,
	allocator := context.allocator,
) -> string {
	if len(env_socket) > 0 {
		return strings.clone(env_socket, allocator)
	}
	if len(cfg_socket) > 0 {
		return strings.clone(cfg_socket, allocator)
	}
	if len(xdg_runtime_dir) > 0 {
		base := strings.trim_right(xdg_runtime_dir, "/")
		return strings.concatenate({base, "/", SOCKET_DIR_NAME, "/", SOCKET_FILE_NAME}, allocator)
	}
	return fmt.aprintf(
		"/run/user/%d/%s/%s",
		uid,
		SOCKET_DIR_NAME,
		SOCKET_FILE_NAME,
		allocator = allocator,
	)
}

// socket_path_error returns "" when path is usable as a control-socket path,
// else a human-readable reason (temp-allocated). The path must be absolute,
// name a file (not end in '/') and fit in sockaddr_un.sun_path with its NUL.
socket_path_error :: proc(path: string) -> string {
	if len(path) == 0 {
		return "control socket path is empty"
	}
	if !strings.has_prefix(path, "/") {
		return fmt.tprintf("control socket path %q is not absolute", path)
	}
	if strings.has_suffix(path, "/") {
		return fmt.tprintf("control socket path %q names a directory", path)
	}
	if len(path) > SOCKET_PATH_MAX {
		return fmt.tprintf(
			"control socket path %q is %d bytes; the limit is %d (sockaddr_un holds 108 bytes including the NUL)",
			path,
			len(path),
			SOCKET_PATH_MAX,
		)
	}
	if strings.index_byte(path, 0) >= 0 {
		return "control socket path contains a NUL byte"
	}
	return ""
}

// control_socket_path resolves the path for this process: NWS_SOCKET, then
// cfg_socket, then XDG_RUNTIME_DIR, then /run/user/<real uid>. Validation is
// left to the caller (socket_path_error).
control_socket_path :: proc(cfg_socket: string, allocator := context.allocator) -> string {
	env := os.get_env_alloc("NWS_SOCKET", context.temp_allocator)
	xdg := os.get_env_alloc("XDG_RUNTIME_DIR", context.temp_allocator)
	return resolve_socket_path(env, cfg_socket, xdg, u32(linux.getuid()), allocator)
}

// Socket_Dir_Verdict is what the daemon must do with an existing socket
// parent directory before binding inside it.
Socket_Dir_Verdict :: enum {
	Ok, // a directory we own with mode 0700
	Fix_Mode, // a directory we own with another mode — chmod it to 0700
	Not_Dir, // not a directory (symlinks included: checked with lstat)
	Wrong_Owner, // owned by another uid
}

// socket_dir_verdict classifies the lstat result of the socket's parent
// directory: is_dir, its owner uid and permission bits (mode & 0o7777).
socket_dir_verdict :: proc(is_dir: bool, owner, uid: u32, perm: u32) -> Socket_Dir_Verdict {
	if !is_dir {
		return .Not_Dir
	}
	if owner != uid {
		return .Wrong_Owner
	}
	if perm != 0o700 {
		return .Fix_Mode
	}
	return .Ok
}
