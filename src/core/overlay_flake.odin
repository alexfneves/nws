package core

import "core:slice"
import "core:strings"

// Overlay_Child describes one matched child directory spliced into an
// overlay workspace's package set. `name` is the attribute name under the
// overlay's attrPath (the candidate basename); `rel_path` is its path
// relative to the workspace root, used verbatim in `callPackage ./<rel_path>
// {}` (monorepo splices may contain `/`). Both strings are borrowed by the
// generated text and must outlive the call.
Overlay_Child :: struct {
	name:     string,
	rel_path: string,
}

// generate_overlay_root_flake builds a complete root flake.nix for a
// workspace with `"backend": "overlay"`: it resolves the base package set
// named by each configured attrPath (preferring the flake input's own
// outputs, falling back to the imported overlay source) and splices the
// matched children into that set via `overrideScope'` when it is a fixpoint
// scope (so shadowing propagates to consumers), or a plain attrset merge
// otherwise. This is the create-path shape (ISC-3): a plain user flake whose
// nws block is present — `{` + the block (see generate_overlay_block) + the
// return-set closer `  };` + `}` — with no magic whole-file header. The
// daemon no longer calls it (it patches the block in place), but the shape
// doubles as the minimal fresh flake nws writes when flake.nix is absent,
// and user content added below the block's END marker (still inside the
// outputs return set) survives regenerations.
//
// Like generate_root_flake this is a pure function of its arguments: children
// are emitted sorted by name (ties broken by rel_path), everything is written
// into a fresh builder, and the result is cloned — calling it twice with
// equal inputs yields byte-identical output.
//
// nixpkgs cascade for the inputs section (first match wins):
//  1. cfg.nixpkgs_url != ""            → inputs.nixpkgs.url = <url>
//  2. else any flake overlay entry     → inputs.nixpkgs.follows =
//     "<first-flake-input>/nixpkgs"
//  3. else                             → no nixpkgs input
//
// Non-flake entries (`is_flake == false`) are imported via
// `import (builtins.fetchTarball "<url>")` instead of a flake input.
//
// Children whose name or rel_path cannot be emitted as a Nix path token are
// skipped fail-open (see is_path_token_safe) so the flake stays evaluable.
// With no safe children a minimal valid managed flake is emitted.
// The returned string is allocated from `allocator` and owned by the caller.
generate_overlay_root_flake :: proc(
	matched: []Overlay_Child,
	cfg: Workspace_Config,
	emit_devshell := false,
	allocator := context.allocator,
) -> string {
	block := generate_overlay_block(matched, cfg, emit_devshell, allocator)
	defer delete(block)

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "{\n")
	strings.write_string(&b, block)
	strings.write_string(&b, "  };\n}\n")

	return strings.clone(strings.to_string(b), allocator)
}

// generate_overlay_block builds the nws-managed block for an overlay
// workspace: exactly the body emitted by generate_overlay_root_flake —
// binding names preserved (`spliced0`, `childCalls0`, `base0`, `overlay0`,
// `nixpkgs`, `inputs`) so user attrs referencing block internals survive
// regeneration — wrapped in the NWS_BLOCK_BEGIN…NWS_BLOCK_END markers instead
// of the whole-file header and outer braces. The outputs return set is LEFT
// OPEN at the END marker: the block ends inside `in {` (after the generated
// output attrs) and the surrounding file closes the set (`  };`) and the
// flake (`}`). User output attrs written below the END marker belong to the
// return set and survive regeneration; user content outside the markers is
// never touched. Pure and deterministic like the whole-file form; the
// returned string is allocated from `allocator` and owned by the caller.
generate_overlay_block :: proc(
	matched: []Overlay_Child,
	cfg: Workspace_Config,
	emit_devshell := false,
	allocator := context.allocator,
) -> string {
	emit := overlay_emit_children(matched, allocator)
	defer delete(emit)

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, NWS_BLOCK_BEGIN)
	strings.write_string(&b, "\n")
	write_overlay_body(&b, emit[:], cfg, emit_devshell)
	strings.write_string(&b, NWS_BLOCK_END)
	strings.write_string(&b, "\n")

	return strings.clone(strings.to_string(b), allocator)
}

// overlay_emit_children returns matched children sorted by name (ties broken
// by rel_path) with any child whose name or rel_path cannot be emitted as a
// bare Nix path token dropped (see is_path_token_safe), so the generated
// flake stays evaluable. Such paths (spaces, quotes, backslashes, `#`, `${`,
// control chars, or empty) simply cannot be represented and are omitted from
// childCalls, packages.<system> and default alike rather than breaking every
// generated flake. The returned slice is allocated from allocator, owned by
// the caller, and shares nothing with matched.
overlay_emit_children :: proc(
	matched: []Overlay_Child,
	allocator := context.allocator,
) -> [dynamic]Overlay_Child {
	sorted := make([dynamic]Overlay_Child, 0, len(matched), allocator)
	defer delete(sorted)
	for c in matched {
		append(&sorted, c)
	}
	slice.sort_by(sorted[:], proc(a, b: Overlay_Child) -> bool {
		if a.name != b.name {
			return a.name < b.name
		}
		return a.rel_path < b.rel_path
	})

	emit := make([dynamic]Overlay_Child, 0, len(sorted), allocator)
	for c in sorted {
		if is_path_token_safe(c.rel_path) && is_path_token_safe(c.name) {
			append(&emit, c)
		}
	}
	return emit
}

// write_overlay_body writes the nws-owned body of an overlay root flake:
// everything that lives between the NWS_BLOCK_BEGIN/NWS_BLOCK_END markers of
// the block form (and, wrapped in the top-level `{ ... }`, of the whole-file
// create shape). The outputs return set is LEFT OPEN: the last line emitted
// is the final generated output attr, and the block's END marker follows
// inside the set. Zero safe children yields the minimal valid body.
write_overlay_body :: proc(
	b: ^strings.Builder,
	emit: []Overlay_Child,
	cfg: Workspace_Config,
	emit_devshell: bool,
) {
	// Zero safe children: minimal valid managed flake (its nws block still
	// marks the flake as serviced by the daemon) — an empty outputs return
	// set, left open for the END marker; the surrounding file closes it with
	// `  };` and the flake with `}`.
	if len(emit) == 0 {
		strings.write_string(b, "  outputs = { ... }@inputs:\n")
		strings.write_string(b, "  {\n")
		return
	}

	// --- inputs section ---
	flake_count := 0
	for ov in cfg.overlays {
		if !ov.is_flake {
			continue
		}
		if flake_count == 0 {
			strings.write_string(b, "  inputs = {\n")
		}
		strings.write_string(b, "    ")
		write_input_name(b, flake_count)
		strings.write_string(b, `.url = "`)
		nix_escape_string(b, ov.url)
		strings.write_string(b, "\";\n")
		flake_count += 1
	}
	use_follows := false
	if len(cfg.nixpkgs_url) > 0 {
		if flake_count == 0 {
			strings.write_string(b, "  inputs = {\n")
		}
		strings.write_string(b, `    nixpkgs.url = "`)
		nix_escape_string(b, cfg.nixpkgs_url)
		strings.write_string(b, "\";\n")
	} else if flake_count > 0 {
		// Cascade step 2: follow the first flake overlay's nixpkgs.
		use_follows = true
		strings.write_string(b, "    nixpkgs.follows = \"")
		write_input_name(b, 0)
		strings.write_string(b, "/nixpkgs\";\n")
	}
	if flake_count > 0 || len(cfg.nixpkgs_url) > 0 {
		strings.write_string(b, "  };\n")
	}

	// --- outputs section ---
	strings.write_string(b, "  outputs = { ... }@inputs:\n  let\n")
	// Base-set resolution per entry: prefer the attrPath on the flake input
	// itself (nix-ros-overlay-style flakes expose e.g.
	// legacyPackages.<system>.<distro> directly as outputs), falling back to
	// the attrPath on the resolved overlay value (an already-overlaid pkgs
	// set, e.g. one exposing rosPackages.<distro>).
	for i in 0 ..< len(cfg.overlays) {
		ap_i := cfg.overlays[i].attr_path
		if len(ap_i) == 0 {
			ap_i = "pkgs"
		}
		strings.write_string(b, "    baseViaInput")
		write_int(b, i)
		strings.write_string(b, " = ")
		if cfg.overlays[i].is_flake {
			strings.write_string(b, "inputs.")
			write_input_name(b, i)
			strings.write_byte(b, '.')
			write_attr_path(b, ap_i)
			strings.write_string(b, " or null;\n")
			strings.write_string(b, "    overlaySource")
			write_int(b, i)
			strings.write_string(b, " = import inputs.")
			write_input_name(b, i)
			strings.write_string(b, ";\n")
		} else {
			// Non-flake entry: plain expression fetched as a tarball (ISC-13);
			// there is no flake output to consult directly.
			strings.write_string(b, "null;\n")
			strings.write_string(b, "    overlaySource")
			write_int(b, i)
			strings.write_string(b, " = ")
			strings.write_string(b, `import (builtins.fetchTarball "`)
			nix_escape_string(b, cfg.overlays[i].url)
			strings.write_string(b, "\");\n")
		}
		// Overlay sources come in two shapes: a function returning an
		// already-overlaid pkgs set (e.g. nix-ros-overlay's default.nix) or a
		// ready set. A system argument is required under flake eval because
		// builtins.currentSystem is unavailable.
		strings.write_string(b, "    overlayResolved")
		write_int(b, i)
		strings.write_string(b, " = if builtins.isFunction overlaySource")
		write_int(b, i)
		strings.write_string(b, " then overlaySource")
		write_int(b, i)
		strings.write_string(b, " { system = \"")
		strings.write_string(b, system_from_attr_path(ap_i))
		strings.write_string(b, "\"; } else overlaySource")
		write_int(b, i)
		strings.write_string(b, ";\n")
		strings.write_string(b, "    base")
		write_int(b, i)
		strings.write_string(b, " =\n      if baseViaInput")
		write_int(b, i)
		strings.write_string(b, " != null\n      then baseViaInput")
		write_int(b, i)
		strings.write_string(b, "\n      else (overlayResolved")
		write_int(b, i)
		strings.write_byte(b, '.')
		write_attr_path(b, ap_i)
		strings.write_string(b, " or {});\n")
	}

	// One splice per configured overlay entry: resolve the base set at the
	// attrPath (walking the overlaid pkgs), then extend it so that shadowing
	// actually propagates to consumers of the set:
	//  - sets exposing `overrideScope'` (fixpoint scopes like nixpkgs
	//    legacyPackages / rosPackages): re-extend the scope, calling each
	//    child with `prev.callPackage` so siblings see each other via final;
	//  - plain attrsets: fall back to `base // mapAttrs apply childCalls`.
	// Children calls are emitted once as an attrset of functions (`childCalls`)
	// shared by both branches. Each child call first checks for a user override
	// expression at `./.nws/packages/<name>.nix` and uses it via callPackage when
	// present. v1 targets the single-entry case; multi-entry
	// simply repeats the splice set per attrPath.
	for e in 0 ..< len(cfg.overlays) {
		strings.write_string(b, "    childCalls")
		write_int(b, e)
		strings.write_string(b, " = {\n")
		for c in emit {
			strings.write_string(b, "      ")
			write_attr_key(b, c.name)
			// Per-child user override hook: when the workspace has a hidden
			// .nws/packages/<name>.nix, it is called with callPackage against
			// the spliced scope (so sibling-named deps resolve locally).
			// Absence of the file falls through to the bare source build.
			// Paths are emitted as unquoted Nix path tokens — quoted strings
			// fail Nix eval; unsafe names are already skipped above.
			strings.write_string(b, " = prev:\n        if builtins.pathExists ./.nws/packages/")
			strings.write_string(b, c.name)
			strings.write_string(b, ".nix\n")
			strings.write_string(b, "        then prev.callPackage ./.nws/packages/")
			strings.write_string(b, c.name)
			strings.write_string(b, ".nix { }\n")
			// When the child name exists in the spliced scope, src-override
			// it: dependencies are inherited from the overlay rather than re-parsed.
			strings.write_string(b, "        else if (prev.")
			write_attr_key(b, c.name)
			strings.write_string(b, " or null) != null\n")
			strings.write_string(b, "        then prev.")
			write_attr_key(b, c.name)
			strings.write_string(b, ".overrideAttrs (final: { src = ./")
			strings.write_string(b, c.rel_path)
			strings.write_string(b, "; })\n")
			// Raw source checkouts (no default.nix) are built through the
			// distro scope's buildRosPackage; plain callPackage remains as the
			// fallback for scopes without it.
			strings.write_string(b, "        else if (prev.buildRosPackage or null) != null\n")
			strings.write_string(b, "        then prev.buildRosPackage {\n")
			strings.write_string(b, "          pname = \"")
			nix_escape_string(b, c.name)
			strings.write_string(b, "\";\n")
			strings.write_string(b, "          version = \"0.0.0\";\n")
			strings.write_string(b, "          src = ./")
			strings.write_string(b, c.rel_path)
			strings.write_string(b, ";\n")
			strings.write_string(b, "        }\n")
			strings.write_string(b, "        else prev.callPackage ./")
			strings.write_string(b, c.rel_path)
			strings.write_string(b, " { };\n")
		}
		strings.write_string(b, "    };\n")

		strings.write_string(b, "    spliced")
		write_int(b, e)
		strings.write_string(b, " =\n      if (base")
		write_int(b, e)
		strings.write_string(b, ".overrideScope' or null) != null\n")
		strings.write_string(b, "      then base")
		write_int(b, e)
		strings.write_string(
			b,
			".overrideScope' (final: prev: builtins.mapAttrs (_: f: f prev) childCalls",
		)
		write_int(b, e)
		strings.write_string(b, ")\n")
		strings.write_string(b, "      else base")
		write_int(b, e)
		strings.write_string(b, " // builtins.mapAttrs (_: f: f base")
		write_int(b, e)
		strings.write_string(b, ") childCalls")
		write_int(b, e)
		strings.write_string(b, ";\n")
	}

	// The `in` boundary: splice bindings above live in the let, everything
	// below is the flake's output attrset.
	strings.write_string(b, "  in\n  {\n")

	// One output attribute per configured overlay entry: the spliced set.
	// An entry whose attrPath IS the convenience packages.<system> attr
	// (e.g. `packages.x86_64-linux` — Hyprland-style overlays expose their
	// package set at exactly that path) would collide with the convenience
	// output below, so it is emitted in the MERGED form instead: the full
	// spliced set preserved via a Nix `//` merge with the convenience body
	// (children + default) on top — body keys win, but they are the same
	// children already in the spliced set, plus `default` only the body has.
	for e in 0 ..< len(cfg.overlays) {
		ap := cfg.overlays[e].attr_path
		if len(ap) == 0 {
			ap = "pkgs"
		}
		strings.write_string(b, "    ")
		if attr_path_is_packages_set(ap) {
			strings.write_string(b, ap)
			strings.write_string(b, " = spliced")
			write_int(b, e)
			strings.write_string(b, " // ")
			write_packages_default_body(b, emit, cfg, system_from_attr_path(ap))
		} else {
			write_attr_path(b, ap)
			strings.write_string(b, " = spliced")
			write_int(b, e)
			strings.write_string(b, ";\n")
		}
	}

	// Convenience direct-build output: packages.<system> exposing every
	// matched child from the first configured entry. The system is taken from
	// the attrPath when it contains a recognizable <cpu>-<os> segment,
	// otherwise defaults to x86_64-linux. Skipped when entry 0's attrPath IS
	// packages.<system> — the merged per-entry form above already carries the
	// exact same body under that attr.
	first_ap := "pkgs"
	if len(cfg.overlays) > 0 && len(cfg.overlays[0].attr_path) > 0 {
		first_ap = cfg.overlays[0].attr_path
	}
	sys := system_from_attr_path(first_ap)
	if !attr_path_is_packages_set(first_ap) {
		strings.write_string(b, "    packages.")
		strings.write_string(b, sys)
		strings.write_string(b, " = ")
		write_packages_default_body(b, emit, cfg, sys)
	}

	// Managed devShell (standard nix-ros-overlay pattern, see
	// write_devshell_attr): emitted when the workspace configures
	// dev_shell_packages AND a nixpkgs input exists for pkgsN (follows
	// cascade or explicit nixpkgs.url). All-non-flake overlays without a
	// nixpkgs input skip it fail-open; the sync also suppresses emission
	// when the user already owns a devShell (user content wins) unless they
	// opted into the nested devShell block markers.
	if emit_devshell && (len(cfg.nixpkgs_url) > 0 || has_flake_overlay(cfg)) {
		write_devshell_attr(b, emit, cfg, sys)
	}
}

// attr_path_is_packages_set reports whether path is exactly the convenience
// `packages.<system>` output attr (e.g. `packages.x86_64-linux`): a dotted
// path with a `packages.` prefix whose remainder is the system segment
// system_from_attr_path extracts (i.e. a single <cpu>-<os> name). A
// per-entry output at such a path would collide with the convenience output,
// so it is emitted in the merged form instead.
attr_path_is_packages_set :: proc(path: string) -> bool {
	if !strings.has_prefix(path, "packages.") {
		return false
	}
	// "packages." is 9 bytes; the remainder must be exactly the system
	// segment (a lone <cpu>-<os> token) for the collision to hold.
	rest := path[9:len(path)]
	return len(rest) > 0 && rest == system_from_attr_path(path)
}

// write_packages_default_body writes the attrset body of the convenience
// `packages.<system>` output: every matched child wired to the first entry's
// spliced set plus the `default` buildEnv aggregation for a bare `nix build`.
// Shared by the standalone convenience output (`packages.<sys> = ` + body)
// and the merged form emitted when an entry's attrPath IS packages.<system>
// (`packages.<sys> = spliced<e> // ` + body): in the merged form the body
// keys win the `//` merge — the children are the same ones already in the
// spliced set, and `default` exists only in the body.
write_packages_default_body :: proc(
	b: ^strings.Builder,
	emit: []Overlay_Child,
	cfg: Workspace_Config,
	sys: string,
) {
	strings.write_string(b, "{\n")
	for c in emit {
		strings.write_string(b, "      ")
		write_attr_key(b, c.name)
		strings.write_string(b, " = spliced0.")
		write_attr_key(b, c.name)
		strings.write_string(b, ";\n")
	}

	// Bare `nix build` requires packages.<system>.default to be a DERIVATION
	// (Nix rejects an attrset there: "expected a derivation or path but found
	// a set"). Aggregate all spliced children with a nixpkgs buildEnv so a
	// bare `nix build` installs the whole substitution set. The nixpkgs input
	// is present via the cascade chain (nixpkgs.follows) or an explicit
	// nixpkgs.url; when neither exists (all non-flake overlays) fall back to
	// the first child so the attribute remains a valid derivation.
	strings.write_string(b, "      default = (if builtins.hasAttr \"nixpkgs\" inputs then\n")
	strings.write_string(b, "        (import inputs.nixpkgs { system = \"")
	strings.write_string(b, sys)
	strings.write_string(b, "\"; }).buildEnv {\n")
	strings.write_string(b, "          name = \"nws-workspace-env\";\n")
	strings.write_string(b, "          paths = [\n")
	for c in emit {
		strings.write_string(b, "            spliced0.")
		write_attr_key(b, c.name)
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "          ];\n")
	strings.write_string(b, "        }\n")
	strings.write_string(b, "      else spliced0.")
	write_attr_key(b, emit[0].name)
	strings.write_string(b, ");\n")
	strings.write_string(b, "    };\n")
}

// has_flake_overlay reports whether cfg has at least one flake overlay entry
// (those bring inputs.nixpkgs via the follows cascade).
has_flake_overlay :: proc(cfg: Workspace_Config) -> bool {
	for ov in cfg.overlays {
		if ov.is_flake {
			return true
		}
	}
	return false
}

// write_devshell_attr emits a devShells.<system>.default output following the
// standard nix-ros-overlay devShell shape: mkShell whose `packages` holds a
// single spliced0.buildEnv env. No shellHook, no env-var manipulation — the
// packages' own setup hooks wire ROS_PACKAGE_PATH/GAZEBO_PLUGIN_PATH etc.
write_devshell_attr :: proc(
	b: ^strings.Builder,
	emit: []Overlay_Child,
	cfg: Workspace_Config,
	sys: string,
) {
	strings.write_string(b, "    devShells.")
	strings.write_string(b, sys)
	strings.write_string(b, ".default = let\n")
	strings.write_string(b, "      pkgsN = import inputs.nixpkgs { system = \"")
	strings.write_string(b, sys)
	strings.write_string(b, "\"; };\n")
	write_devshell_env_binding(b, emit, cfg, "      ")
	strings.write_string(b, "    in pkgsN.mkShell {\n")
	strings.write_string(b, "      name = \"nws-dev-shell\";\n")
	strings.write_string(b, "      packages = [ env ];\n")
	strings.write_string(b, "    };\n")
}

// build_devshell_fragment renders the nested managed devShell block (its
// BEGIN and END marker lines around the env binding) for injection INSIDE a
// user's own devShell `let` (PATCH mode): the user writes
// `packages = [ env ];` in their own mkShell and nws manages only the marked
// region. Owned by the caller; delete it when done.
build_devshell_fragment :: proc(
	emit: []Overlay_Child,
	cfg: Workspace_Config,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, NWS_DEVSHELL_BLOCK_BEGIN)
	strings.write_string(&b, "\n")
	write_devshell_env_binding(&b, emit, cfg, "  ")
	strings.write_string(&b, NWS_DEVSHELL_BLOCK_END)
	strings.write_string(&b, "\n")
	return strings.clone(strings.to_string(b), allocator)
}

// write_devshell_env_binding writes the `env = spliced0.buildEnv {...}`
// binding shared by both devShell shapes (full attr AND nested block).
// Children are listed FIRST: buildEnv collision resolution keeps the
// first-listed path, so the src-override (clone) builds must precede any
// original overlay build that sibling children propagate into the env —
// otherwise the upstream files win the merge and the local clones are
// shadowed. `ignoreCollisions = true` tolerates those same-package pairs
// (clone build + propagated original of the same package in one env).
write_devshell_env_binding :: proc(
	b: ^strings.Builder,
	emit: []Overlay_Child,
	cfg: Workspace_Config,
	indent: string,
) {
	strings.write_string(b, indent)
	strings.write_string(b, "env = spliced0.buildEnv {\n")
	strings.write_string(b, indent)
	strings.write_string(b, "  name = \"nws-dev-env\";\n")
	strings.write_string(b, indent)
	strings.write_string(b, "  ignoreCollisions = true;\n")
	strings.write_string(b, indent)
	strings.write_string(b, "  paths = [\n")
	for c in emit {
		strings.write_string(b, indent)
		strings.write_string(b, "    spliced0.")
		write_attr_key(b, c.name)
		strings.write_string(b, "\n")
	}
	for p in cfg.dev_shell_packages {
		strings.write_string(b, indent)
		strings.write_string(b, "    spliced0.")
		write_attr_key(b, p)
		strings.write_string(b, "\n")
	}
	strings.write_string(b, indent)
	strings.write_string(b, "  ];\n")
	strings.write_string(b, indent)
	strings.write_string(b, "};\n")
}

// write_input_name writes the flake input name for the i-th *flake* overlay
// entry ("overlay0", "overlay1", ...) — deterministic and always a valid Nix
// identifier regardless of the URL contents.
write_input_name :: proc(b: ^strings.Builder, i: int) {
	strings.write_string(b, "overlay")
	write_int(b, i)
}

// write_int writes i in decimal (i >= 0).
write_int :: proc(b: ^strings.Builder, i: int) {
	n := i
	if n == 0 {
		strings.write_rune(b, '0')
		return
	}
	digits: [20]byte
	count := 0
	for n > 0 {
		digits[count] = byte('0' + n % 10)
		n /= 10
		count += 1
	}
	for j := count - 1; j >= 0; j -= 1 {
		strings.write_byte(b, digits[j])
	}
}

// is_path_token_safe reports whether s can be emitted as an unquoted Nix path
// token. Nix path tokens must be non-empty and cannot contain whitespace,
// quotes, backslashes, `#`, `${`, or control characters.
is_path_token_safe :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == ' ' ||
		   c == '\t' ||
		   c == '\n' ||
		   c == '\r' ||
		   c < 32 ||
		   c == '"' ||
		   c == '\\' ||
		   c == '#' {
			return false
		}
		// Nix anti-quotation: literal ${ inside an interpolation begins a
		// string escape that would consume the rest of the token.
		if c == '$' && i + 1 < len(s) && s[i + 1] == '{' {
			return false
		}
	}
	return true
}

// write_attr_path writes a dotted attrPath ("rosPackages.humble") as bare
// attrset keys (works both in definition and selector position), quoting any
// segment that is not a valid Nix identifier.
write_attr_path :: proc(b: ^strings.Builder, path: string) {
	segs := strings.split(path, ".")
	defer delete(segs)
	for seg, i in segs {
		if i > 0 {
			strings.write_byte(b, '.')
		}
		write_attr_key(b, seg)
	}
}

// system_from_attr_path extracts a system tuple ("<cpu>-<os>") from a dotted
// attrPath: the first segment ending in "-linux" or "-darwin" is returned
// verbatim. When no segment matches, "x86_64-linux" is used as the default.
system_from_attr_path :: proc(path: string) -> string {
	seg_start := 0
	for i := 0; i <= len(path); i += 1 {
		if i == len(path) || path[i] == '.' {
			seg := path[seg_start:i]
			if strings.has_suffix(seg, "-linux") || strings.has_suffix(seg, "-darwin") {
				return seg
			}
			seg_start = i + 1
		}
	}
	return "x86_64-linux"
}
