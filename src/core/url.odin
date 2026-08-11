package core

import "core:strings"

// encode percent-encodes a path for the wire: space -> "%20", '%' -> "%25",
// all other bytes (including '/') are passed through unchanged.
encode :: proc(path: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

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

	return strings.clone(strings.to_string(b), allocator)
}

// decode reverses percent-encoding: "%20" -> space, "%25" -> '%'. Returns
// (decoded, ok); ok=false if the input ends with a dangling '%' or contains
// a malformed hex escape.
decode :: proc(s: string, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' {
			if i + 2 >= len(s) {
				return "", false
			}
			hi := hex_val(s[i + 1])
			lo := hex_val(s[i + 2])
			if hi < 0 || lo < 0 {
				return "", false
			}
			strings.write_byte(&b, u8(hi * 16 + lo))
			i += 3
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}

	return strings.clone(strings.to_string(b), allocator), true
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
