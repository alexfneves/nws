package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// Resolution order: NWS_SOCKET, then config "socket", then XDG_RUNTIME_DIR,
// then /run/user/<uid>.
@(test)
test_socket_path_resolution_order :: proc(t: ^testing.T) {
	Case :: struct {
		env, cfg, xdg: string,
		uid:           u32,
		want:          string,
	}
	cases := []Case {
		{"/e/nws.sock", "/c/nws.sock", "/run/user/7", 7, "/e/nws.sock"},
		{"", "/c/nws.sock", "/run/user/7", 7, "/c/nws.sock"},
		{"", "", "/run/user/7", 7, "/run/user/7/nws/control.sock"},
		{"", "", "/tmp/xdg/", 7, "/tmp/xdg/nws/control.sock"},
		{"", "", "", 1000, "/run/user/1000/nws/control.sock"},
		{"", "", "", 0, "/run/user/0/nws/control.sock"},
	}
	for c, i in cases {
		got := core.resolve_socket_path(c.env, c.cfg, c.xdg, c.uid)
		defer delete(got)
		testing.expectf(t, got == c.want, "case %d: got %q want %q", i, got, c.want)
	}
}

// sockaddr_un holds 108 bytes including the NUL: 107 fits, 108 does not.
@(test)
test_socket_path_length_limit :: proc(t: ^testing.T) {
	fits := strings.concatenate({"/", strings.repeat("a", 106, context.temp_allocator)})
	defer delete(fits)
	testing.expectf(t, len(fits) == 107, "setup: want 107 bytes, got %d", len(fits))
	testing.expectf(t, core.socket_path_error(fits) == "", "107-byte path must be accepted")

	too_long := strings.concatenate({fits, "b"})
	defer delete(too_long)
	msg := core.socket_path_error(too_long)
	testing.expectf(t, msg != "", "108-byte path must be refused")
	testing.expectf(t, strings.contains(msg, "108"), "error should name the limit: %q", msg)

	testing.expectf(t, core.socket_path_error("") != "", "empty path must be refused")
	testing.expectf(t, core.socket_path_error("rel/nws.sock") != "", "relative path refused")
	testing.expectf(t, core.socket_path_error("/run/user/1/nws/") != "", "directory refused")
	testing.expectf(t, core.socket_path_error("/run/user/1/nws/control.sock") == "", "default ok")
}

// The parent-directory policy: our own 0700 dir is fine, our own looser dir
// gets fixed, anything else is refused.
@(test)
test_socket_dir_verdict :: proc(t: ^testing.T) {
	testing.expect(t, core.socket_dir_verdict(true, 1000, 1000, 0o700) == .Ok)
	testing.expect(t, core.socket_dir_verdict(true, 1000, 1000, 0o755) == .Fix_Mode)
	testing.expect(t, core.socket_dir_verdict(true, 1000, 1000, 0o1700) == .Fix_Mode)
	testing.expect(t, core.socket_dir_verdict(true, 0, 1000, 0o700) == .Wrong_Owner)
	testing.expect(t, core.socket_dir_verdict(false, 1000, 1000, 0o700) == .Not_Dir)
}
