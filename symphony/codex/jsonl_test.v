module codex

fn test_jsonl_decoder_reassembles_every_byte_split() {
	line := '{"id":1,"result":{"ok":true}}\n'
	for split := 0; split <= line.len; split++ {
		mut decoder := new_jsonl_decoder(1024) or { panic(err) }
		mut frames := []string{}
		frames << decoder.feed(line[..split]) or { panic(err) }
		frames << decoder.feed(line[split..]) or { panic(err) }
		assert frames == ['{"id":1,"result":{"ok":true}}']
		assert decoder.finish() or { panic(err) } == []string{}
	}
}

fn test_jsonl_decoder_handles_multiple_frames_blank_lines_and_crlf() {
	mut decoder := new_jsonl_decoder(1024) or { panic(err) }
	frames := decoder.feed('\n {"id":1}\r\n\n{"id":2}\n') or { panic(err) }
	assert frames == [' {"id":1}', '{"id":2}']
}

fn test_jsonl_decoder_rejects_invalid_and_oversized_frames() {
	mut invalid := new_jsonl_decoder(1024) or { panic(err) }
	invalid.feed('not-json\n') or {
		assert err.msg().contains('invalid_jsonl')
		mut oversized := new_jsonl_decoder(5) or { panic(err) }
		oversized.feed('{"long":true}') or {
			assert err.msg().contains('jsonl_line_too_large')
			return
		}
		assert false, 'oversized frame should fail'
	}
	assert false, 'invalid JSON should fail'
}

fn test_jsonl_decoder_rejects_unterminated_final_frame() {
	mut decoder := new_jsonl_decoder(1024) or { panic(err) }
	decoder.feed('{"id":1}') or { panic(err) }
	decoder.finish() or {
		assert err.msg().contains('unterminated_jsonl')
		return
	}
	assert false, 'unterminated final frame should fail'
}
