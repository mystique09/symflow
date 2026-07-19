module dotenv

import os
import strings

const max_file_bytes = 1_048_576
const max_line_bytes = 65_536

// LoadResult reports a dotenv load without retaining any parsed values.
pub struct LoadResult {
pub:
	path    string
	found   bool
	applied int
}

struct ParsedLine {
	skip  bool
	name  string
	value string
}

// parse validates dotenv text and returns its last assignment for each name.
pub fn parse(source string) !map[string]string {
	if source.len > max_file_bytes {
		return error('dotenv_file_too_large: environment file exceeds 1 MiB')
	}
	normalized := source.replace('\r\n', '\n').replace('\r', '\n')
	mut values := map[string]string{}
	for index, line in normalized.split('\n') {
		line_number := index + 1
		if line.len > max_line_bytes {
			return error('dotenv_line_too_long: line ${line_number} exceeds 64 KiB')
		}
		entry := parse_line(line, line_number)!
		if !entry.skip {
			values[entry.name] = entry.value
		}
	}
	return values
}

// load fills variables absent from the current process environment.
pub fn load(path string, required bool) !LoadResult {
	absolute_path := os.abs_path(path)
	if !os.exists(absolute_path) {
		if required {
			return error('dotenv_file_error: unable to read `${absolute_path}`')
		}
		return LoadResult{
			path: absolute_path
		}
	}
	if !os.is_file(absolute_path) {
		return error('dotenv_file_error: `${absolute_path}` is not a regular file')
	}
	if os.file_size(absolute_path) > max_file_bytes {
		return error('dotenv_file_too_large: `${absolute_path}` exceeds 1 MiB')
	}
	source := os.read_file(absolute_path) or {
		return error('dotenv_file_error: unable to read `${absolute_path}`')
	}
	values := parse(source)!
	mut applied := 0
	for name, value in values {
		if _ := os.getenv_opt(name) {
			continue
		}
		if os.setenv(name, value, false) != 0 {
			return error('dotenv_environment_error: unable to set `${name}`')
		}
		applied++
	}
	return LoadResult{
		path:    absolute_path
		found:   true
		applied: applied
	}
}

fn parse_line(line string, line_number int) !ParsedLine {
	mut source := line.trim_space()
	if source == '' || source.starts_with('#') {
		return ParsedLine{
			skip: true
		}
	}
	if source.len > 6 && source.starts_with('export') && source[6].is_space() {
		source = source[7..].trim_left(' \t')
	}
	separator := source.index('=') or {
		return line_error(line_number, 'assignment is missing `=`')
	}
	name := source[..separator].trim_space()
	if !valid_name(name) {
		return line_error(line_number, 'invalid variable name')
	}
	value := parse_value(source[separator + 1..], line_number)!
	return ParsedLine{
		name:  name
		value: value
	}
}

fn parse_value(raw string, line_number int) !string {
	had_leading_space := raw != '' && raw[0].is_space()
	source := raw.trim_space()
	if source == '' {
		return ''
	}
	if source[0] == `'` {
		return parse_single_quoted(source, line_number)
	}
	if source[0] == `"` {
		return parse_double_quoted(source, line_number)
	}
	mut end := source.len
	for index, character in source {
		if character == `#` && ((index == 0 && had_leading_space)
			|| (index > 0 && source[index - 1].is_space())) {
			end = index
			break
		}
	}
	return source[..end].trim_space()
}

fn parse_single_quoted(source string, line_number int) !string {
	mut closing := -1
	for index := 1; index < source.len; index++ {
		if source[index] == `'` {
			closing = index
			break
		}
	}
	if closing < 0 {
		return line_error(line_number, 'unterminated single-quoted value')
	}
	validate_quoted_tail(source[closing + 1..], line_number)!
	return source[1..closing]
}

fn parse_double_quoted(source string, line_number int) !string {
	mut value := strings.new_builder(source.len)
	mut index := 1
	for index < source.len {
		character := source[index]
		if character == `"` {
			validate_quoted_tail(source[index + 1..], line_number)!
			return value.str()
		}
		if character == `\\` && index + 1 < source.len {
			next := source[index + 1]
			match next {
				`n` {
					value.write_u8(`\n`)
				}
				`r` {
					value.write_u8(`\r`)
				}
				`t` {
					value.write_u8(`\t`)
				}
				`\\` {
					value.write_u8(`\\`)
				}
				`"` {
					value.write_u8(`"`)
				}
				else {
					value.write_u8(`\\`)
					value.write_u8(next)
				}
			}
			index += 2
			continue
		}
		value.write_u8(character)
		index++
	}
	return line_error(line_number, 'unterminated double-quoted value')
}

fn validate_quoted_tail(tail string, line_number int) ! {
	if tail == '' {
		return
	}
	if !tail[0].is_space() {
		return line_error(line_number, 'unexpected content after quoted value')
	}
	remaining := tail.trim_space()
	if remaining != '' && !remaining.starts_with('#') {
		return line_error(line_number, 'unexpected content after quoted value')
	}
}

fn valid_name(name string) bool {
	if name == '' || (!ascii_letter(name[0]) && name[0] != `_`) {
		return false
	}
	for character in name.bytes()[1..] {
		if !ascii_letter(character) && !character.is_digit() && character != `_` {
			return false
		}
	}
	return true
}

fn ascii_letter(character u8) bool {
	return (character >= `a` && character <= `z`) || (character >= `A` && character <= `Z`)
}

fn line_error(line_number int, reason string) IError {
	return error('dotenv_parse_error: line ${line_number}: ${reason}')
}
