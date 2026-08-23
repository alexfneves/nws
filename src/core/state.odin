package core

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// State holds the persisted canonical-URL mapping:
// workspace path -> repo name -> canonical URL. It lets the daemon restore
// a removed clone's input to its GitHub URL instead of pinning it locally.
State :: struct {
	workspaces: map[string]map[string]string,
}

// new_state returns an empty State using the given allocator.
new_state :: proc(allocator := context.allocator) -> State {
	return State{workspaces = make(map[string]map[string]string, allocator)}
}

// destroy_state frees all keys, values, inner maps, and the outer map.
destroy_state :: proc(s: ^State) {
	for ws_key, repos in s.workspaces {
		delete(ws_key)
		for repo_key, url in repos {
			delete(repo_key)
			delete(url)
		}
		delete(repos)
	}
	delete(s.workspaces)
	s.workspaces = nil
}

// load_state reads and parses state.json. A missing or corrupt file returns
// an empty State with ok=false rather than crashing.
load_state :: proc(path: string, allocator := context.allocator) -> (State, bool) {
	s := new_state(allocator)

	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return s, false
	}
	defer delete(data, allocator)

	v, err := json.parse(data, allocator = allocator)
	if err != nil {
		return s, false
	}
	defer json.destroy_value(v, allocator)

	obj, is_obj := v.(json.Object)
	if !is_obj {
		return s, false
	}

	ws_v, has := obj["workspaces"]
	if !has {
		return s, false
	}
	ws_obj, is_ws_obj := ws_v.(json.Object)
	if !is_ws_obj {
		return s, false
	}

	for ws_path, repos_v in ws_obj {
		repos_obj, ok_repos := repos_v.(json.Object)
		if !ok_repos {
			continue
		}
		repos := make(map[string]string, allocator)
		for repo_name, url_v in repos_obj {
			url_str, ok_url := url_v.(json.String)
			if !ok_url {
				continue
			}
			repos[strings.clone(repo_name, allocator)] = strings.clone(url_str, allocator)
		}
		s.workspaces[strings.clone(ws_path, allocator)] = repos
	}

	return s, true
}

// save_state writes s as JSON to path atomically (temp file in the same
// directory + rename), ensuring the parent directory exists first.
save_state :: proc(path: string, s: ^State, allocator := context.allocator) -> bool {
	dir := parent_dir(path)
	if dir != "" && !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return false
		}
	}

	text := build_state_json(s, allocator)
	defer delete(text, allocator)

	tmp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(tmp, text); err != nil {
		os.remove(tmp)
		return false
	}

	if err := os.rename(tmp, path); err != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// prune_workspace removes all repo entries for the given workspace path.
// Returns true if anything was removed.
prune_workspace :: proc(s: ^State, ws: string, allocator := context.allocator) -> bool {
	repos, has := s.workspaces[ws]
	if !has {
		return false
	}
	for k, v in repos {
		delete(k, allocator)
		delete(v, allocator)
	}
	delete(repos)
	del_key, _ := delete_key(&s.workspaces, ws)
	delete(del_key, allocator)
	return true
}

// upsert_url records (or overwrites) the canonical URL for a repo inside a
// workspace, creating intermediate maps as needed.
upsert_url :: proc(s: ^State, ws, repo, url: string, allocator := context.allocator) {
	repos, has := s.workspaces[ws]
	if !has {
		repos = make(map[string]string, allocator)
		s.workspaces[strings.clone(ws, allocator)] = repos
	} else if _, has_old := repos[repo]; has_old {
		old_key, old_url := delete_key(&repos, repo)
		delete(old_key, allocator)
		delete(old_url, allocator)
	}
	repos[strings.clone(repo, allocator)] = strings.clone(url, allocator)
	// Maps have value semantics in Odin 2026-07a: write the mutated map back.
	s.workspaces[ws] = repos
}

// lookup_url fetches the stored canonical URL for ws/repo; second return is
// false when no entry exists.
lookup_url :: proc(s: ^State, ws, repo: string) -> (string, bool) {
	repos, has_ws := s.workspaces[ws]
	if !has_ws {
		return "", false
	}
	url, has_repo := repos[repo]
	return url, has_repo
}

// build_state_json hand-writes the state file as pretty JSON text.
build_state_json :: proc(s: ^State, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "{\n  \"workspaces\": {")
	first_ws := true
	ws_keys := sorted_map_keys(&s.workspaces, allocator)
	defer delete(ws_keys)
	for ws in ws_keys {
		if !first_ws {
			strings.write_string(&b, ",")
		}
		first_ws = false
		strings.write_string(&b, "\n    \"")
		strings.write_string(&b, json_escape(ws, allocator))
		strings.write_string(&b, "\": {")

		repos := s.workspaces[ws]
		first_repo := true
		repo_keys := sorted_map_keys(&repos, allocator)
		defer delete(repo_keys)
		for repo in repo_keys {
			if !first_repo {
				strings.write_string(&b, ",")
			}
			first_repo = false
			strings.write_string(&b, "\n      \"")
			strings.write_string(&b, json_escape(repo, allocator))
			strings.write_string(&b, "\": \"")
			strings.write_string(&b, json_escape(repos[repo], allocator))
			strings.write_string(&b, "\"")
		}
		if len(repos) > 0 {
			strings.write_string(&b, "\n    ")
		}
		strings.write_string(&b, "}")
	}
	if len(s.workspaces) > 0 {
		strings.write_string(&b, "\n  ")
	}
	strings.write_string(&b, "}\n}\n")

	return strings.clone(strings.to_string(b), allocator)
}

// sorted_map_keys returns the map's keys sorted lexicographically so output
// bytes are deterministic regardless of map iteration order.
sorted_map_keys :: proc(m: ^map[string]$V, allocator := context.allocator) -> [dynamic]string {
	keys := make([dynamic]string, 0, len(m^), allocator)
	for k in m {
		append(&keys, k)
	}
	slice.sort(keys[:])
	return keys
}
