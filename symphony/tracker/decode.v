module tracker

import json2
import time

fn valid_timestamp(value string) string {
	if value == '' {
		return ''
	}
	time.parse_iso8601(value) or { return '' }
	return value
}

fn map_value(values map[string]json2.Any, key string) map[string]json2.Any {
	return (values[key] or { return map[string]json2.Any{} }).as_map()
}

fn array_value(values map[string]json2.Any, key string) []json2.Any {
	return (values[key] or { return []json2.Any{} }).as_array()
}

fn string_value(values map[string]json2.Any, key string) string {
	value := values[key] or { return '' }
	return if value is string { value } else { '' }
}

fn bool_value(values map[string]json2.Any, key string) bool {
	value := values[key] or { return false }
	return if value is bool { value } else { false }
}
