package core

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Workspace_Kind selects the backend used to generate a workspace's root flake.
Workspace_Kind :: enum {
	flake,
	overlay,
}

// Overlay_Entry describes one upstream overlay flake spliced into the root.
Overlay_Entry :: struct {
	url:          string, // overlay flake URL, e.g. "github:lopsided98/nix-ros-overlay/master"
	attr_path:    string, // package-set attribute path, e.g. "rosPackages.humble"
	overlay_attr: string, // overlays.<overlayAttr> applied; empty = "default"
	is_flake:     bool, // false → plain expression imported via builtins.fetchTarball
}

// Workspace_Config is one entry of Config.workspaces. Legacy configs stored
// bare path strings; those load as kind = .flake with no overlays.
Workspace_Config :: struct {
	name:        string,
	kind:        Workspace_Kind,
	overlays:    [dynamic]Overlay_Entry,
	nixpkgs_url: string, // "" = nixpkgs cascade decides (see plan)
}

// Config holds the persisted daemon settings.
Config :: struct {
	port:       int,
	workspaces: [dynamic]Workspace_Config,
}

// DEFAULT_PORT is the TCP control-socket port used when config.json has no
// "port" key (or no config file exists).
DEFAULT_PORT :: 17424

// load_config reads and parses config.json. Missing keys fall back to
// defaults and a missing/corrupt file returns defaults rather than crashing.
// The second return reports whether a valid "port"/"workspaces" object was
// actually parsed from the file.
load_config :: proc(path: string, allocator := context.allocator) -> (Config, bool) {
	cfg := Config {
		port = DEFAULT_PORT,
	}
	cfg.workspaces = make([dynamic]Workspace_Config, allocator)

	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return cfg, false
	}
	defer delete(data, allocator)

	v, err := json.parse(data, allocator = allocator)
	if err != nil {
		return cfg, false
	}
	defer json.destroy_value(v, allocator)

	obj, is_obj := v.(json.Object)
	if !is_obj {
		return cfg, false
	}

	if port_v, has := obj["port"]; has {
		#partial switch p in port_v {
		case json.Integer:
			cfg.port = int(p)
		case json.Float:
			cfg.port = int(p)
		}
	}

	if ws_v, has := obj["workspaces"]; has {
		#partial switch ws in ws_v {
		case json.Array:
			for elem in ws {
				parse_workspace_entry(elem, &cfg.workspaces, allocator)
			}
		}
	}

	return cfg, true
}

// parse_workspace_entry decodes one element of the "workspaces" array. Both
// forms are accepted:
//   - a plain string (legacy) → Workspace_Config{name = s, kind = .flake}
//   - an object with "name", optional "backend", "overlays", "nixpkgs"
// Unknown fields are ignored and malformed entries are skipped (fail-open).
parse_workspace_entry :: proc(
	v: json.Value,
	out: ^[dynamic]Workspace_Config,
	allocator: mem.Allocator,
) {
	#partial switch s in v {
	case json.String:
		ws := Workspace_Config {
			name = strings.clone(s, allocator),
		}
		append(out, ws)
		return
	}

	obj, is_obj := v.(json.Object)
	if !is_obj {
		return
	}
	name_v, has_name := obj["name"]
	name_s, name_ok := name_v.(json.String)
	if !has_name || !name_ok || len(name_s) == 0 {
		return // a workspace without a path is useless — skip
	}
	ws := Workspace_Config {
		name = strings.clone(name_s, allocator),
	}

	if be_v, has := obj["backend"]; has {
		#partial switch be in be_v {
		case json.String:
			switch be {
			case "overlay":
				ws.kind = .overlay
			case: // "flake" and anything else → default .flake
			}
		}
	}

	if ov_v, has := obj["overlays"]; has {
		#partial switch arr in ov_v {
		case json.Array:
			ws.overlays = make([dynamic]Overlay_Entry, 0, allocator)
			for ev in arr {
				entry, ok := parse_overlay_entry(ev, allocator)
				if ok {
					append(&ws.overlays, entry)
				}
			}
		}
	}

	if np_v, has := obj["nixpkgs"]; has {
		#partial switch np in np_v {
		case json.String:
			ws.nixpkgs_url = strings.clone(np, allocator)
		}
	}

	append(out, ws)
}

// parse_overlay_entry decodes one object of a workspace's "overlays" array.
// Required: "url" and "attrPath". Optional: "overlayAttr" (default "default"
// at use time), "flake" (default true). Missing url/attrPath → not ok.
parse_overlay_entry :: proc(v: json.Value, allocator: mem.Allocator) -> (Overlay_Entry, bool) {
	entry: Overlay_Entry
	entry.is_flake = true

	obj, is_obj := v.(json.Object)
	if !is_obj {
		return entry, false
	}

	url_v, has := obj["url"]
	url_s, url_ok := url_v.(json.String)
	if !has || !url_ok || len(url_s) == 0 {
		return entry, false
	}
	attr_v, attr_has := obj["attrPath"]
	attr_s, attr_ok := attr_v.(json.String)
	if !attr_has || !attr_ok || len(attr_s) == 0 {
		return entry, false
	}
	entry.url = strings.clone(url_s, allocator)
	entry.attr_path = strings.clone(attr_s, allocator)

	if oa_v, oa_has := obj["overlayAttr"]; oa_has {
		#partial switch oa in oa_v {
		case json.String:
			entry.overlay_attr = strings.clone(oa, allocator)
		}
	}

	if fl_v, fl_has := obj["flake"]; fl_has {
		#partial switch fl in fl_v {
		case json.Boolean:
			entry.is_flake = fl
		}
	}

	return entry, true
}

// save_config writes cfg as JSON to path. It ensures the parent directory
// exists and writes atomically (temp file in the same directory + rename) so
// a crash mid-write never leaves a truncated config.json.
save_config :: proc(path: string, cfg: Config, allocator := context.allocator) -> bool {
	dir := parent_dir(path)
	if dir != "" && !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return false
		}
	}

	text := build_config_json(cfg, allocator)
	defer delete(text, allocator)

	tmp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(tmp, text); err != nil {
		return false
	}
	defer os.remove(tmp)

	if err := os.rename(tmp, path); err != nil {
		return false
	}
	return true
}

// build_config_json hand-writes the config file as pretty JSON text.
build_config_json :: proc(cfg: Config, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "{\n")
	strings.write_string(&b, fmt.tprintf("  \"port\": %d,\n", cfg.port))
	strings.write_string(&b, "  \"workspaces\": [")
	for ws, i in cfg.workspaces {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		if ws.kind == .overlay {
			write_workspace_object(&b, ws, allocator)
		} else {
			// Legacy form: a plain quoted path keeps old configs byte-stable.
			strings.write_string(&b, "\"")
			strings.write_string(&b, json_escape(ws.name, allocator))
			strings.write_string(&b, "\"")
		}
	}
	strings.write_string(&b, "]\n}\n")

	return strings.clone(strings.to_string(b), allocator)
}

// write_workspace_object emits an overlay workspace as a JSON object.
write_workspace_object :: proc(
	b: ^strings.Builder,
	ws: Workspace_Config,
	allocator: mem.Allocator,
) {
	strings.write_string(b, "{\n")
	strings.write_string(
		b,
		fmt.tprintf("    \"name\": \"%s\",\n", json_escape(ws.name, allocator)),
	)
	strings.write_string(b, "    \"backend\": \"overlay\",\n")
	if len(ws.overlays) > 0 {
		strings.write_string(b, "    \"overlays\": [\n")
		for ov, i in ws.overlays {
			strings.write_string(b, "      {\n")
			strings.write_string(
				b,
				fmt.tprintf("        \"url\": \"%s\",\n", json_escape(ov.url, allocator)),
			)
			strings.write_string(
				b,
				fmt.tprintf("        \"attrPath\": \"%s\"", json_escape(ov.attr_path, allocator)),
			)
			if len(ov.overlay_attr) > 0 {
				strings.write_string(b, ",\n")
				strings.write_string(
					b,
					fmt.tprintf(
						"        \"overlayAttr\": \"%s\"",
						json_escape(ov.overlay_attr, allocator),
					),
				)
			}
			if !ov.is_flake {
				strings.write_string(b, ",\n")
				strings.write_string(b, "        \"flake\": false")
			}
			strings.write_string(b, "\n      }")
			if i < len(ws.overlays) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		strings.write_string(b, "    ],\n")
	}
	if len(ws.nixpkgs_url) > 0 {
		strings.write_string(
			b,
			fmt.tprintf("    \"nixpkgs\": \"%s\",\n", json_escape(ws.nixpkgs_url, allocator)),
		)
	}
	strings.write_string(b, "  }")
}

// clone_workspace_config deep-copies one Workspace_Config (name, overlay
// entries, nixpkgs URL) into freshly allocated strings owned by the caller.
// Free the result with delete_workspace_config.
clone_workspace_config :: proc(
	ws: Workspace_Config,
	allocator := context.allocator,
) -> Workspace_Config {
	out := Workspace_Config {
		kind        = ws.kind,
		nixpkgs_url = ws.nixpkgs_url != "" ? strings.clone(ws.nixpkgs_url, allocator) : "",
	}
	out.name = strings.clone(ws.name, allocator)
	if len(ws.overlays) > 0 {
		out.overlays = make([dynamic]Overlay_Entry, 0, len(ws.overlays), allocator)
		for ov in ws.overlays {
			append(
				&out.overlays,
				Overlay_Entry {
					url = strings.clone(ov.url, allocator),
					attr_path = strings.clone(ov.attr_path, allocator),
					overlay_attr = ov.overlay_attr != "" ? strings.clone(ov.overlay_attr, allocator) : "",
					is_flake = ov.is_flake,
				},
			)
		}
	}
	return out
}

// delete_workspaces frees every workspace (names, overlay entries, URLs) and
// the backing array.
delete_workspaces :: proc(cfg: ^Config) {
	for ws in cfg.workspaces {
		delete_workspace_config(ws)
	}
	delete(cfg.workspaces)
}

// delete_workspace_config frees the heap-owned strings of one entry.
delete_workspace_config :: proc(ws: Workspace_Config) {
	delete(ws.name)
	for ov in ws.overlays {
		delete(ov.url)
		delete(ov.attr_path)
		if len(ov.overlay_attr) > 0 {
			delete(ov.overlay_attr)
		}
	}
	if ws.overlays != nil {
		delete(ws.overlays)
	}
	if len(ws.nixpkgs_url) > 0 {
		delete(ws.nixpkgs_url)
	}
}

// workspace_configs_equal reports whether two Workspace_Configs carry the same
// settings (by value; order-sensitive for overlays).
workspace_configs_equal :: proc(a, b: Workspace_Config) -> bool {
	if a.name != b.name || a.kind != b.kind || a.nixpkgs_url != b.nixpkgs_url {
		return false
	}
	if len(a.overlays) != len(b.overlays) {
		return false
	}
	for i in 0 ..< len(a.overlays) {
		x, y := a.overlays[i], b.overlays[i]
		if x.url != y.url ||
		   x.attr_path != y.attr_path ||
		   x.overlay_attr != y.overlay_attr ||
		   x.is_flake != y.is_flake {
			return false
		}
	}
	return true
}

// json_escape escapes backslashes and double quotes for safe inclusion inside
// a JSON string value.
json_escape :: proc(s: string, allocator := context.allocator) -> string {
	escaped, _ := strings.replace_all(s, `\`, `\\`, allocator)
	escaped, _ = strings.replace_all(escaped, `"`, `\"`, allocator)
	return escaped
}

// parent_dir returns the directory portion of path, or "" if path has no '/'.
parent_dir :: proc(path: string) -> string {
	idx := strings.last_index_byte(path, '/')
	if idx < 0 {
		return ""
	}
	return path[:idx]
}
