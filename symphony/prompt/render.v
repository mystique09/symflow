module prompt

import json2
import strings
import symphony.domain

const max_template_bytes = 512 * 1024
const max_rendered_bytes = 2 * 1024 * 1024

enum ScopeKind {
	none
	string_value
	blocker
}

struct RenderScope {
	issue   domain.Issue
	attempt int
	kind    ScopeKind
	value   string
	blocker domain.BlockerRef
}

struct BlockMatch {
	body        string
	next_offset int
}

pub fn render(template string, issue domain.Issue, attempt int) !string {
	if template.len > max_template_bytes {
		return error('template_parse_error: template exceeds ${max_template_bytes} bytes')
	}
	result := render_segment(template, RenderScope{
		issue:   issue
		attempt: attempt
	})!
	if result.len > max_rendered_bytes {
		return error('template_render_error: rendered prompt exceeds ${max_rendered_bytes} bytes')
	}
	return result
}

fn render_segment(template string, scope RenderScope) !string {
	mut output := strings.new_builder(template.len)
	mut cursor := 0
	for cursor < template.len {
		relative_open := template[cursor..].index('{{') or {
			output.write_string(template[cursor..])
			break
		}
		open := cursor + relative_open
		output.write_string(template[cursor..open])
		relative_close := template[open + 2..].index('}}') or {
			return error('template_parse_error: unclosed tag at offset ${open}')
		}
		close := open + 2 + relative_close
		tag := template[open + 2..close].trim_space()
		after_tag := close + 2
		if tag.starts_with('#if ') {
			expression := tag[4..].trim_space()
			block := find_matching_block(template, after_tag, 'if', open)!
			if is_truthy(expression, scope, open)! {
				output.write_string(render_segment(block.body, scope)!)
			}
			cursor = block.next_offset
			continue
		}
		if tag.starts_with('#each ') {
			expression := tag[6..].trim_space()
			block := find_matching_block(template, after_tag, 'each', open)!
			match expression {
				'issue.labels' {
					for label in scope.issue.labels {
						output.write_string(render_segment(block.body, RenderScope{
							...scope
							kind:  .string_value
							value: label
						})!)
					}
				}
				'issue.blocked_by' {
					for blocker in scope.issue.blocked_by {
						output.write_string(render_segment(block.body, RenderScope{
							...scope
							kind:    .blocker
							blocker: blocker
						})!)
					}
				}
				else {
					return error('template_render_error: unknown iterable `${expression}` at offset ${open}')
				}
			}
			cursor = block.next_offset
			continue
		}
		if tag.starts_with('/') {
			return error('template_parse_error: unexpected closing block `${tag}` at offset ${open}')
		}
		if tag == '' {
			return error('template_parse_error: empty interpolation at offset ${open}')
		}
		output.write_string(evaluate(tag, scope, open)!)
		cursor = after_tag
	}
	return output.str()
}

fn find_matching_block(template string, content_start int, expected string, opening_offset int) !BlockMatch {
	mut stack := [expected]
	mut cursor := content_start
	for cursor < template.len {
		relative_open := template[cursor..].index('{{') or { break }
		open := cursor + relative_open
		relative_close := template[open + 2..].index('}}') or {
			return error('template_parse_error: unclosed tag at offset ${open}')
		}
		close := open + 2 + relative_close
		tag := template[open + 2..close].trim_space()
		if tag.starts_with('#if ') {
			stack << 'if'
		} else if tag.starts_with('#each ') {
			stack << 'each'
		} else if tag.starts_with('/') {
			closing := tag[1..].trim_space()
			if stack.len == 0 || closing != stack.last() {
				wanted := if stack.len == 0 { expected } else { stack.last() }
				return error('template_parse_error: mismatched block `/${closing}`, expected `/${wanted}` at offset ${open}')
			}
			stack.delete_last()
			if stack.len == 0 {
				return BlockMatch{
					body:        template[content_start..open]
					next_offset: close + 2
				}
			}
		}
		cursor = close + 2
	}
	return error('template_parse_error: unclosed `${expected}` block at offset ${opening_offset}')
}

fn is_truthy(expression string, scope RenderScope, offset int) !bool {
	return match expression {
		'issue.labels' { scope.issue.labels.len > 0 }
		'issue.blocked_by' { scope.issue.blocked_by.len > 0 }
		else { resolve_scalar(expression, scope, offset)! != '' }
	}
}

fn evaluate(expression string, scope RenderScope, offset int) !string {
	parts := expression.split('|')
	mut value := resolve_scalar(parts[0].trim_space(), scope, offset)!
	for raw_filter in parts[1..] {
		filter := raw_filter.trim_space()
		match filter {
			'lower' {
				value = value.to_lower()
			}
			'upper' {
				value = value.to_upper()
			}
			'trim' {
				value = value.trim_space()
			}
			else {
				if filter.starts_with('default:') {
					if value == '' {
						value = unquote(filter.all_after(':').trim_space())!
					}
				} else {
					return error('template_render_error: unknown filter `${filter}` at offset ${offset}')
				}
			}
		}
	}
	return value
}

fn unquote(value string) !string {
	if value.len >= 2 && ((value[0] == `"` && value[value.len - 1] == `"`)
		|| (value[0] == `'` && value[value.len - 1] == `'`)) {
		return value[1..value.len - 1]
	}
	if value != '' && !value.contains(' ') {
		return value
	}
	return error('template_render_error: default filter value must be quoted')
}

fn resolve_scalar(path string, scope RenderScope, offset int) !string {
	return match path {
		'attempt' {
			if scope.attempt < 0 {
				''
			} else {
				scope.attempt.str()
			}
		}
		'issue.id' {
			scope.issue.id
		}
		'issue.identifier' {
			scope.issue.identifier
		}
		'issue.title' {
			scope.issue.title
		}
		'issue.description' {
			scope.issue.description
		}
		'issue.priority' {
			if scope.issue.priority < 0 {
				''
			} else {
				scope.issue.priority.str()
			}
		}
		'issue.state' {
			scope.issue.state
		}
		'issue.branch_name' {
			scope.issue.branch_name
		}
		'issue.url' {
			scope.issue.url
		}
		'issue.created_at' {
			scope.issue.created_at
		}
		'issue.updated_at' {
			scope.issue.updated_at
		}
		'issue.assignee_id' {
			scope.issue.assignee_id
		}
		'issue.native_ref' {
			json2.encode(scope.issue.native_ref, escape_unicode: true)
		}
		'issue.dispatchable' {
			scope.issue.dispatchable.str()
		}
		'this' {
			if scope.kind == .string_value {
				scope.value
			} else {
				return error('template_render_error: `this` is only available inside a string iteration at offset ${offset}')
			}
		}
		'this.id' {
			if scope.kind == .blocker {
				scope.blocker.id
			} else {
				return error('template_render_error: `this.id` is only available inside a blocker iteration at offset ${offset}')
			}
		}
		'this.identifier' {
			if scope.kind == .blocker {
				scope.blocker.identifier
			} else {
				return error('template_render_error: `this.identifier` is only available inside a blocker iteration at offset ${offset}')
			}
		}
		'this.state' {
			if scope.kind == .blocker {
				scope.blocker.state
			} else {
				return error('template_render_error: `this.state` is only available inside a blocker iteration at offset ${offset}')
			}
		}
		'this.created_at' {
			if scope.kind == .blocker {
				scope.blocker.created_at
			} else {
				return error('template_render_error: `this.created_at` is only available inside a blocker iteration at offset ${offset}')
			}
		}
		'this.updated_at' {
			if scope.kind == .blocker {
				scope.blocker.updated_at
			} else {
				return error('template_render_error: `this.updated_at` is only available inside a blocker iteration at offset ${offset}')
			}
		}
		else {
			return error('template_render_error: unknown variable `${path}` at offset ${offset}')
		}
	}
}
