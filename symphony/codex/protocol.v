module codex

import json2
import strconv
import symphony.domain

struct ClientInfo {
	name    string
	version string
}

struct InitializeParams {
	client_info  ClientInfo @[json: clientInfo]
	capabilities ClientCapabilities
}

struct ClientCapabilities {
	experimental_api bool @[json: experimentalApi]
}

struct InitializeRequest {
	id     int
	method string
	params InitializeParams
}

struct ThreadStartParams {
	cwd             string
	approval_policy json2.Any @[json: approvalPolicy; omitempty]
	sandbox         string    @[omitempty]
	ephemeral       bool
}

struct ThreadStartRequest {
	id     int
	method string
	params ThreadStartParams
}

struct TextInput {
	typ  string @[json: type]
	text string
}

struct TurnStartParams {
	thread_id       string @[json: threadId]
	input           []TextInput
	cwd             string
	approval_policy json2.Any @[json: approvalPolicy]
	sandbox_policy  json2.Any @[json: sandboxPolicy]
}

struct TurnStartRequest {
	id     int
	method string
	params TurnStartParams
}

struct TurnInterruptParams {
	thread_id string @[json: threadId]
	turn_id   string @[json: turnId]
}

struct TurnInterruptRequest {
	id     int
	method string
	params TurnInterruptParams
}

pub fn initialize_request(id int) string {
	return json2.encode(InitializeRequest{
		id:     id
		method: 'initialize'
		params: InitializeParams{
			client_info:  ClientInfo{
				name:    'symphony-v'
				version: '0.1.0'
			}
			capabilities: ClientCapabilities{
				experimental_api: true
			}
		}
	})
}

struct ToolFailureContent {
	typ  string @[json: type]
	text string
}

struct ToolFailureResult {
	success       bool
	content_items []ToolFailureContent @[json: contentItems]
}

struct ToolFailureResponse {
	id     json2.Any
	result ToolFailureResult
}

pub fn dynamic_tool_failure_response(request_id string, message string) string {
	mut id := json2.Any(request_id)
	if numeric_id := strconv.atoi(request_id) {
		id = json2.Any(numeric_id)
	}
	return json2.encode(ToolFailureResponse{
		id:     id
		result: ToolFailureResult{
			success:       false
			content_items: [
				ToolFailureContent{
					typ:  'inputText'
					text: message
				},
			]
		}
	})
}

pub fn initialized_notification() string {
	return '{"method":"initialized"}'
}

pub fn thread_start_request(id int, cwd string, approval_policy string, sandbox string) string {
	return json2.encode(ThreadStartRequest{
		id:     id
		method: 'thread/start'
		params: ThreadStartParams{
			cwd:             cwd
			approval_policy: policy_json_value(approval_policy)
			sandbox:         sandbox
			ephemeral:       false
		}
	})
}

pub fn turn_start_request(id int, thread_id string, prompt string, cwd string, approval_policy string, sandbox_policy string) string {
	policy := sandbox_json_value(sandbox_policy, cwd)
	return json2.encode(TurnStartRequest{
		id:     id
		method: 'turn/start'
		params: TurnStartParams{
			thread_id:       thread_id
			cwd:             cwd
			approval_policy: policy_json_value(approval_policy)
			sandbox_policy:  policy
			input:           [TextInput{
				typ:  'text'
				text: prompt
			}]
		}
	})
}

fn policy_json_value(source string) json2.Any {
	trimmed := source.trim_space()
	if trimmed.starts_with('{') || trimmed.starts_with('[') || trimmed.starts_with('"') {
		return json2.decode[json2.Any](trimmed) or { json2.Any(source) }
	}
	return json2.Any(source)
}

fn sandbox_json_value(source string, cwd string) json2.Any {
	trimmed := source.trim_space()
	if trimmed.starts_with('{') {
		return json2.decode[json2.Any](trimmed) or { json2.Any(map[string]json2.Any{}) }
	}
	mut policy := map[string]json2.Any{}
	policy['type'] = json2.Any(source)
	if source == 'workspaceWrite' {
		policy['writableRoots'] = json2.Any([json2.Any(cwd)])
	}
	return json2.Any(policy)
}

pub fn turn_interrupt_request(id int, thread_id string, turn_id string) string {
	return json2.encode(TurnInterruptRequest{
		id:     id
		method: 'turn/interrupt'
		params: TurnInterruptParams{
			thread_id: thread_id
			turn_id:   turn_id
		}
	})
}

pub enum ProtocolEventKind {
	response
	thread_started
	turn_started
	turn_completed
	token_usage
	rate_limits
	blocked
	tool_call
	notification
	protocol_error
}

pub struct ProtocolEvent {
pub:
	kind              ProtocolEventKind
	request_id        string
	method            string
	thread_id         string
	turn_id           string
	status            string
	error_message     string
	tokens            domain.TokenTotals
	rate_used_percent int
	rate_resets_at    i64
	raw               string
}

pub fn interpret(line string) !ProtocolEvent {
	decoded := json2.decode[json2.Any](line) or {
		return error('protocol_decode_error: ${err.msg()}')
	}
	root := decoded.as_map()
	if root.len == 0 {
		return error('protocol_decode_error: message must be a JSON object')
	}
	method := string_value(root, 'method')
	request_id := string_value(root, 'id')
	if method != '' {
		if request_id != '' && method == 'item/tool/call' {
			params := map_value(root, 'params')
			return ProtocolEvent{
				kind:       .tool_call
				request_id: request_id
				method:     method
				thread_id:  string_value(params, 'threadId')
				turn_id:    string_value(params, 'turnId')
				raw:        bounded_raw(line)
			}
		}
		if request_id != '' && is_blocking_request(method) {
			params := map_value(root, 'params')
			return ProtocolEvent{
				kind:       .blocked
				request_id: request_id
				method:     method
				thread_id:  string_value(params, 'threadId')
				turn_id:    string_value(params, 'turnId')
				raw:        bounded_raw(line)
			}
		}
		return interpret_method(method, request_id, root, line)
	}
	return interpret_response(request_id, root, line)
}

fn interpret_method(method string, request_id string, root map[string]json2.Any, line string) ProtocolEvent {
	params := map_value(root, 'params')
	thread_id := string_value(params, 'threadId')
	return match method {
		'thread/started' {
			thread_data := map_value(params, 'thread')
			ProtocolEvent{
				kind:      .thread_started
				method:    method
				thread_id: string_value(thread_data, 'id')
				raw:       bounded_raw(line)
			}
		}
		'turn/started' {
			turn := map_value(params, 'turn')
			ProtocolEvent{
				kind:      .turn_started
				method:    method
				thread_id: thread_id
				turn_id:   string_value(turn, 'id')
				status:    string_value(turn, 'status')
				raw:       bounded_raw(line)
			}
		}
		'turn/completed' {
			turn := map_value(params, 'turn')
			turn_error := map_value(turn, 'error')
			ProtocolEvent{
				kind:          .turn_completed
				method:        method
				thread_id:     thread_id
				turn_id:       string_value(turn, 'id')
				status:        string_value(turn, 'status')
				error_message: string_value(turn_error, 'message')
				raw:           bounded_raw(line)
			}
		}
		'thread/tokenUsage/updated' {
			usage := map_value(params, 'tokenUsage')
			total := map_value(usage, 'total')
			ProtocolEvent{
				kind:      .token_usage
				method:    method
				thread_id: thread_id
				turn_id:   string_value(params, 'turnId')
				tokens:    domain.TokenTotals{
					input:  i64_value(total, 'inputTokens')
					output: i64_value(total, 'outputTokens')
					total:  i64_value(total, 'totalTokens')
				}
				raw:       bounded_raw(line)
			}
		}
		'account/rateLimits/updated' {
			rate_limits := map_value(params, 'rateLimits')
			primary := map_value(rate_limits, 'primary')
			ProtocolEvent{
				kind:              .rate_limits
				method:            method
				rate_used_percent: int_value(primary, 'usedPercent')
				rate_resets_at:    i64_value(primary, 'resetsAt')
				raw:               bounded_raw(line)
			}
		}
		else {
			ProtocolEvent{
				kind:       .notification
				request_id: request_id
				method:     method
				thread_id:  thread_id
				turn_id:    string_value(params, 'turnId')
				raw:        bounded_raw(line)
			}
		}
	}
}

fn interpret_response(request_id string, root map[string]json2.Any, line string) ProtocolEvent {
	error_value := map_value(root, 'error')
	if error_value.len > 0 {
		return ProtocolEvent{
			kind:          .protocol_error
			request_id:    request_id
			error_message: string_value(error_value, 'message')
			raw:           bounded_raw(line)
		}
	}
	result := map_value(root, 'result')
	thread_data := map_value(result, 'thread')
	turn := map_value(result, 'turn')
	return ProtocolEvent{
		kind:       .response
		request_id: request_id
		thread_id:  string_value(thread_data, 'id')
		turn_id:    string_value(turn, 'id')
		status:     string_value(turn, 'status')
		raw:        bounded_raw(line)
	}
}

fn is_blocking_request(method string) bool {
	return method in ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
		'item/tool/requestUserInput', 'mcpServer/elicitation/request',
		'item/permissions/requestApproval', 'applyPatchApproval', 'execCommandApproval']
}

fn map_value(values map[string]json2.Any, key string) map[string]json2.Any {
	return (values[key] or { return map[string]json2.Any{} }).as_map()
}

fn string_value(values map[string]json2.Any, key string) string {
	return (values[key] or { return '' }).str()
}

fn int_value(values map[string]json2.Any, key string) int {
	return (values[key] or { return 0 }).int()
}

fn i64_value(values map[string]json2.Any, key string) i64 {
	return (values[key] or { return i64(0) }).i64()
}

fn bounded_raw(line string) string {
	if line.len <= 4_096 {
		return line
	}
	return line[..4_096]
}
