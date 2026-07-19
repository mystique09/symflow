module dotenv

import os
import time

fn test_parse_supports_common_dotenv_syntax() {
	source := '# host configuration\n export LINEAR_API_KEY="line\\nkey"\nREPOSITORY=git@github.com:acme/repo.git # clone target\nLITERAL=\'a # b\'\nFRAGMENT=https://example.com/repo#readme\nEMPTY=\nQUOTED_EMPTY=""\nREPOSITORY=https://github.com/acme/repo.git\n'
	values := parse(source)!
	assert values['LINEAR_API_KEY'] == 'line\nkey'
	assert values['REPOSITORY'] == 'https://github.com/acme/repo.git'
	assert values['LITERAL'] == 'a # b'
	assert values['FRAGMENT'] == 'https://example.com/repo#readme'
	assert values['EMPTY'] == ''
	assert values['QUOTED_EMPTY'] == ''
}

fn test_parse_preserves_unknown_double_quote_escapes() {
	values := parse('WINDOWS_PATH="C:\\workspace\\folder"')!
	assert values['WINDOWS_PATH'] == r'C:\workspace\folder'
}

fn test_parse_rejects_invalid_names_without_leaking_values() {
	parse('BAD-NAME=secret-value') or {
		assert err.msg().contains('dotenv_parse_error: line 1')
		assert err.msg().contains('invalid variable name')
		assert !err.msg().contains('secret-value')
		return
	}
	assert false
}

fn test_parse_rejects_unterminated_and_trailing_quoted_content() {
	parse('SECRET="not-closed') or {
		assert err.msg().contains('dotenv_parse_error: line 1')
		assert err.msg().contains('unterminated double-quoted value')
		assert !err.msg().contains('not-closed')
	}
	parse("SECRET='closed' trailing") or {
		assert err.msg().contains('dotenv_parse_error: line 1')
		assert err.msg().contains('unexpected content after quoted value')
		assert !err.msg().contains('trailing')
		return
	}
	assert false
}

fn test_parse_requires_whitespace_before_comments_after_quoted_values() {
	parse('SECRET="supersecret"#comment') or {
		assert err.msg().contains('dotenv_parse_error: line 1')
		assert err.msg().contains('unexpected content after quoted value')
		assert !err.msg().contains('supersecret')
	}
	parse("SECRET='anothersecret'#comment") or {
		assert err.msg().contains('dotenv_parse_error: line 1')
		assert err.msg().contains('unexpected content after quoted value')
		assert !err.msg().contains('anothersecret')
		return
	}
	assert false
}

fn test_parse_rejects_oversized_files_and_lines() {
	parse('A=' + 'x'.repeat(1_048_576)) or {
		assert err.msg().contains('dotenv_file_too_large')
		assert !err.msg().contains('xxxxx')
	}
	parse('A=' + 'x'.repeat(65_536)) or {
		assert err.msg().contains('dotenv_line_too_long: line 1')
		assert !err.msg().contains('xxxxx')
		return
	}
	assert false
}

fn test_load_preserves_existing_environment_including_empty_values() {
	dir := dotenv_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	keep_name := 'SYMPHONY_DOTENV_KEEP_${os.getpid()}'
	empty_name := 'SYMPHONY_DOTENV_EMPTY_${os.getpid()}'
	new_name := 'SYMPHONY_DOTENV_NEW_${os.getpid()}'
	for name in [keep_name, empty_name, new_name] {
		os.unsetenv(name)
	}
	defer {
		for name in [keep_name, empty_name, new_name] {
			os.unsetenv(name)
		}
	}
	os.setenv(keep_name, 'shell', true)
	os.setenv(empty_name, '', true)
	path := os.join_path(dir, '.env')
	os.write_file(path, '${keep_name}=file\n${empty_name}=file\n${new_name}=loaded')!
	result := load(path, true)!
	assert result.found
	assert result.path == os.abs_path(path)
	assert result.applied == 1
	assert os.getenv(keep_name) == 'shell'
	assert os.getenv_opt(empty_name)? == ''
	assert os.getenv(new_name) == 'loaded'
}

fn test_load_is_atomic_when_parsing_fails() {
	dir := dotenv_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	name := 'SYMPHONY_DOTENV_ATOMIC_${os.getpid()}'
	os.unsetenv(name)
	defer {
		os.unsetenv(name)
	}
	path := os.join_path(dir, '.env')
	os.write_file(path, '${name}=must-not-apply\nINVALID-NAME=secret')!
	load(path, true) or {
		assert err.msg().contains('dotenv_parse_error: line 2')
		assert os.getenv_opt(name) == none
		return
	}
	assert false
}

fn test_load_treats_missing_default_as_optional_and_explicit_as_required() {
	dir := dotenv_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'missing.env')
	result := load(path, false)!
	assert !result.found
	assert result.applied == 0
	load(path, true) or {
		assert err.msg().contains('dotenv_file_error')
		assert err.msg().contains(os.abs_path(path))
		return
	}
	assert false
}

fn dotenv_test_dir() string {
	path := os.join_path(os.temp_dir(),
		'symphony-dotenv-test-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}
