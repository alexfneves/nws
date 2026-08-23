package core

import "core:strings"

// Wire encoding for the REGISTER control command with overlay options.
//
// A request is a single newline-free line:
//
//	REGISTER <pct(path)>
//	REGISTER <pct(path)>?backend=overlay&overlay=<pct(url)>&attrPath=<pct(a)>...
//
// The path segment is percent-encoded strictly (space, '%', '?', '&', '=' are
// escaped), so the FIRST '?' unambiguously separates it from an optional
// query string. Query keys: `backend` (must be "overlay"), repeatable
// `overlay`/`attrPath` pairs (each overlay needs its attrPath; optional
// per-entry `overlayAttr` and `flake=true|false` apply to the latest
// overlay), and optional workspace-level `nixpkgs`. A bare legacy REGISTER
// (no '?') decodes to a plain flake-kind workspace path.

Register_Request :: struct {
	path:        string,
	overlays:    [dynamic]Overlay_Entry,
	nixpkgs_url: string,
	resolver:    string,
	is_overlay:  bool,
}

// register_encode builds the full REGISTER line (without trailing newline)
// for req. When req.is_overlay is false only the strict-encoded path is
// emitted (legacy form).
register_encode :: proc(req: ^Register_Request, allocator := context.allocator) -> string {
	if !req.is_overlay {
		return pct_encode_strict(req.path, allocator)
	}

	b := strings.builder_make(allocator)
	seg := pct_encode_strict(req.path, allocator)
	strings.write_string(&b, seg)
	delete(seg)
	strings.write_string(&b, "?backend=overlay")
	for ov in req.overlays {
		strings.write_string(&b, "&overlay=")
		seg = pct_encode_strict(ov.url, allocator)
		strings.write_string(&b, seg)
		delete(seg)
		strings.write_string(&b, "&attrPath=")
		seg = pct_encode_strict(ov.attr_path, allocator)
		strings.write_string(&b, seg)
		delete(seg)
		if len(ov.overlay_attr) > 0 {
			strings.write_string(&b, "&overlayAttr=")
			seg = pct_encode_strict(ov.overlay_attr, allocator)
			strings.write_string(&b, seg)
			delete(seg)
		}
		if !ov.is_flake {
			strings.write_string(&b, "&flake=false")
		}
	}
	if len(req.nixpkgs_url) > 0 {
		strings.write_string(&b, "&nixpkgs=")
		seg = pct_encode_strict(req.nixpkgs_url, allocator)
		strings.write_string(&b, seg)
		delete(seg)
	}
	if len(req.resolver) > 0 {
		strings.write_string(&b, "&resolver=")
		seg = pct_encode_strict(req.resolver, allocator)
		strings.write_string(&b, seg)
		delete(seg)
	}
	out := strings.to_string(b)
	res := strings.clone(out, allocator)
	delete(out)
	return res
}

// register_parse splits a REGISTER argument (everything after "REGISTER ")
// into its path and overlay options. Returns ok=false on malformed escapes,
// a non-overlay backend value, or incomplete overlay/attrPath pairing.
register_parse :: proc(
	s: string,
	allocator := context.allocator,
) -> (
	req: Register_Request,
	ok: bool,
) {
	req.overlays = make([dynamic]Overlay_Entry, 0, allocator)

	q := strings.index_byte(s, '?')
	path_part := s
	query := ""
	if q >= 0 {
		path_part = s[:q]
		query = s[q + 1:]
	}

	if len(path_part) == 0 {
		delete(req.overlays)
		return req, false
	}

	dec, dok := decode(path_part, allocator)
	if !dok || len(dec) == 0 {
		delete(dec)
		delete(req.overlays)
		return req, false
	}
	req.path = dec

	if q < 0 {
		return req, true // legacy form: plain flake workspace
	}

	req.is_overlay = true
	cur: Overlay_Entry
	has_cur := false

	pairs, perr := strings.split(query, "&", allocator)
	if perr != nil {
		register_parse_abort(&req)
		return req, false
	}
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		key := pair
		val := ""
		if eq >= 0 {
			key = pair[:eq]
			val = pair[eq + 1:]
		}
		switch key {
		case "backend":
			dv, vok := decode(val, allocator)
			if !vok || dv != "overlay" {
				delete(dv)
				register_parse_abort(&req)
				return req, false
			}
			delete(dv)
			req.is_overlay = true
		case "overlay":
			if has_cur && !overlay_entry_complete(cur) {
				free_overlay_entry(cur)
				register_parse_abort(&req)
				return req, false
			}
			if has_cur {
				append(&req.overlays, cur)
			}
			dv, vok := decode(val, allocator)
			if !vok || len(dv) == 0 {
				delete(dv)
				register_parse_abort(&req)
				return req, false
			}
			cur = Overlay_Entry {
				url      = dv,
				is_flake = true,
			}
			has_cur = true
		case "attrPath":
			if !has_cur {
				register_parse_abort(&req)
				return req, false
			}
			dv, vok := decode(val, allocator)
			if !vok || len(dv) == 0 {
				delete(dv)
				register_parse_abort(&req)
				return req, false
			}
			delete(cur.attr_path)
			cur.attr_path = dv
		case "overlayAttr":
			if !has_cur {
				register_parse_abort(&req)
				return req, false
			}
			dv, vok := decode(val, allocator)
			if !vok {
				register_parse_abort(&req)
				return req, false
			}
			cur.overlay_attr = dv
		case "flake":
			dv, vok := decode(val, allocator)
			if !vok {
				register_parse_abort(&req)
				return req, false
			}
			cur.is_flake = dv != "false"
			delete(dv)
		case "nixpkgs":
			dv, vok := decode(val, allocator)
			if !vok {
				register_parse_abort(&req)
				return req, false
			}
			req.nixpkgs_url = dv
		case "resolver":
			dv, vok := decode(val, allocator)
			if !vok {
				register_parse_abort(&req)
				return req, false
			}
			req.resolver = dv
		case:
		// Unknown parameter: ignore (fail-open forward compatibility).
		}
	}

	if has_cur {
		if !overlay_entry_complete(cur) {
			free_overlay_entry(cur)
			register_parse_abort(&req)
			return req, false
		}
		append(&req.overlays, cur)
	} else if len(req.overlays) == 0 {
		// backend=overlay with no overlay entries is useless — reject.
		register_parse_abort(&req)
		return req, false
	}

	return req, true
}

// register_free frees everything owned by a parsed Register_Request.
register_free :: proc(req: ^Register_Request) {
	delete(req.path)
	for ov in req.overlays {
		free_overlay_entry(ov)
	}
	if req.overlays != nil {
		delete(req.overlays)
	}
	if len(req.nixpkgs_url) > 0 {
		delete(req.nixpkgs_url)
	}
	if len(req.resolver) > 0 {
		delete(req.resolver)
	}
	req.path = ""
	req.overlays = nil
}

overlay_entry_complete :: proc(e: Overlay_Entry) -> bool {
	return len(e.url) > 0 && len(e.attr_path) > 0
}

// free_overlay_entry frees the heap-owned strings of one Overlay_Entry.
free_overlay_entry :: proc(e: Overlay_Entry) {
	delete(e.url)
	delete(e.attr_path)
	if len(e.overlay_attr) > 0 {
		delete(e.overlay_attr)
	}
}

register_parse_abort :: proc(req: ^Register_Request) {
	register_free(req)
}

// pct_encode_strict percent-encodes the bytes that would otherwise be
// ambiguous in a "path?query" REGISTER line: space, '%', '?', '&', '='.
pct_encode_strict :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case ' ':
			strings.write_string(&b, "%20")
		case '%':
			strings.write_string(&b, "%25")
		case '?':
			strings.write_string(&b, "%3F")
		case '&':
			strings.write_string(&b, "%26")
		case '=':
			strings.write_string(&b, "%3D")
		case:
			strings.write_byte(&b, c)
		}
	}

	out := strings.to_string(b)
	res := strings.clone(out, allocator)
	delete(out)
	return res
}
