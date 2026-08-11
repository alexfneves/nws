package core

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Config holds the persisted daemon settings.
Config :: struct {
	port:       int,
	workspaces: [dynamic]string,
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
	cfg.workspaces = make([dynamic]string, allocator)

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
				#partial switch s in elem {
				case json.String:
					append(&cfg.workspaces, strings.clone(s, allocator))
				}
			}
		}
	}

	return cfg, true
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
		strings.write_string(&b, "\"")
		strings.write_string(&b, json_escape(ws, allocator))
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "]\n}\n")

	return strings.clone(strings.to_string(b), allocator)
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
