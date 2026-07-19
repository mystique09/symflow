module codex

import json2

pub struct JsonlDecoder {
	max_line_bytes int
mut:
	buffer string
}

pub fn new_jsonl_decoder(max_line_bytes int) !JsonlDecoder {
	if max_line_bytes <= 0 {
		return error('jsonl_config_error: maximum line size must be positive')
	}
	return JsonlDecoder{
		max_line_bytes: max_line_bytes
	}
}

pub fn (mut decoder JsonlDecoder) feed(chunk string) ![]string {
	decoder.buffer += chunk
	mut frames := []string{}
	for {
		newline := decoder.buffer.index_u8(`\n`)
		if newline < 0 {
			break
		}
		mut frame := decoder.buffer[..newline]
		decoder.buffer = decoder.buffer[newline + 1..]
		if frame.ends_with('\r') {
			frame = frame[..frame.len - 1]
		}
		if frame.trim_space() == '' {
			continue
		}
		if frame.len > decoder.max_line_bytes {
			return error('jsonl_line_too_large: frame exceeds ${decoder.max_line_bytes} bytes')
		}
		json2.decode[json2.Any](frame) or {
			return error('invalid_jsonl: frame is not valid JSON: ${err.msg()}')
		}
		frames << frame
	}
	if decoder.buffer.len > decoder.max_line_bytes {
		return error('jsonl_line_too_large: buffered frame exceeds ${decoder.max_line_bytes} bytes')
	}
	return frames
}

pub fn (mut decoder JsonlDecoder) finish() ![]string {
	if decoder.buffer.trim_space() == '' {
		decoder.buffer = ''
		return []string{}
	}
	return error('unterminated_jsonl: protocol stream ended before a newline')
}
