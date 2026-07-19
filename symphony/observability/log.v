module observability

import json2
import time

pub struct Record {
pub:
	timestamp        string
	level            string = 'info'
	event            string
	issue_id         string
	issue_identifier string
	attempt          int
	session_id       string
	thread_id        string
	turn_id          string
	message          string
}

pub fn render(record Record, secrets []string) string {
	mut safe := record
	mut message := safe.message
	for secret in secrets {
		value := secret.trim_space()
		if value != '' {
			message = message.replace(value, '[REDACTED]')
		}
	}
	if safe.timestamp == '' {
		safe = Record{
			...safe
			timestamp: time.utc().format_rfc3339()
		}
	}
	safe = Record{
		...safe
		message: message
	}
	return json2.encode(safe, escape_unicode: true)
}

pub fn emit(record Record, secrets []string) {
	eprintln(render(record, secrets))
}
