package core

import "core:strings"

// encode percent-encodes a path for the wire: space -> "%20", '%' -> "%25",
// all other bytes (including '/') are passed through unchanged.
encode :: proc(path: string, allocator := context.allocator) -> string {
	// No builder_destroy: strings.to_string consumes the backing buffer and
	// we free it explicitly after cloning.
	b := strings.builder_make(allocator)

	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case ' ':
			strings.write_string(&b, "%20")
		case '%':
			strings.write_string(&b, "%25")
		case:
			strings.write_byte(&b, c)
		}
	}

	out := strings.to_string(b)
	res := strings.clone(out, allocator)
	delete(out)
	return res
}

// decode reverses percent-encoding: "%20" -> space, "%25" -> '%'. Returns
// (decoded, ok); ok=false if the input ends with a dangling '%' or contains
// a malformed hex escape.
decode :: proc(s: string, allocator := context.allocator) -> (string, bool) {
	// No builder_destroy: strings.to_string consumes the backing buffer and
	// we free it explicitly after cloning.
	b := strings.builder_make(allocator)

	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' {
			if i + 2 >= len(s) {
				partial := strings.to_string(b)
				delete(partial)
				return "", false
			}
			hi := hex_val(s[i + 1])
			lo := hex_val(s[i + 2])
			if hi < 0 || lo < 0 {
				partial := strings.to_string(b)
				delete(partial)
				return "", false
			}
			strings.write_byte(&b, u8(hi * 16 + lo))
			i += 3
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}

	out := strings.to_string(b)
	res := strings.clone(out, allocator)
	delete(out)
	return res, true
}

// hex_val returns the value of a single hex digit, or -1 if the byte is not
// a valid hex digit (0-9, a-f, A-F).
hex_val :: proc(c: byte) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10
	}
	return -1
}
