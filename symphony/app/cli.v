module app

import strconv
import symphony.domain
import symphony.prompt
import symphony.tracker
import symphony.workflow

pub enum CommandKind {
	run
	validate
	doctor
	version
	help
}

pub struct Options {
pub:
	command       CommandKind = .run
	workflow_path string      = 'WORKFLOW.md'
	env_path      string      = '.env'
	env_explicit  bool
	once          bool
	web_enabled   bool
	web_host      string = '127.0.0.1'
	web_port      int    = -1
}

pub fn parse_args(args []string) !Options {
	mut command := CommandKind.run
	mut cursor := 0
	mut workflow_path := 'WORKFLOW.md'
	mut has_positional_workflow := false
	if args.len > 0 && !args[0].starts_with('-') {
		match args[0] {
			'run' {
				command = .run
			}
			'validate' {
				command = .validate
			}
			'doctor' {
				command = .doctor
			}
			'version' {
				command = .version
			}
			'help' {
				command = .help
			}
			else {
				workflow_path = args[0]
				has_positional_workflow = true
			}
		}
		cursor++
	}
	mut once := false
	mut env_path := '.env'
	mut env_explicit := false
	mut web_enabled := false
	mut web_host := '127.0.0.1'
	mut web_port := -1
	for cursor < args.len {
		argument := args[cursor]
		match argument {
			'--env' {
				cursor++
				if cursor >= args.len || args[cursor].trim_space() == '' {
					return error('cli_argument_error: --env requires a path')
				}
				env_path = args[cursor]
				env_explicit = true
			}
			'--workflow' {
				cursor++
				if cursor >= args.len || args[cursor].trim_space() == '' {
					return error('cli_argument_error: --workflow requires a path')
				}
				workflow_path = args[cursor]
			}
			'--once' {
				once = true
			}
			'--web' {
				web_enabled = true
			}
			'--web-host' {
				cursor++
				if cursor >= args.len || args[cursor].trim_space() == '' {
					return error('cli_argument_error: --web-host requires a host')
				}
				web_host = args[cursor]
			}
			'--port', '--web-port' {
				cursor++
				if cursor >= args.len {
					return error('cli_argument_error: --web-port requires a number')
				}
				web_port = strconv.atoi(args[cursor]) or {
					return error('cli_argument_error: web port must be a number')
				}
				if web_port < 0 || web_port > 65_535 {
					return error('cli_argument_error: web port must be between 0 and 65535')
				}
				web_enabled = true
			}
			'-h', '--help' {
				command = .help
			}
			else {
				if !argument.starts_with('-') && !has_positional_workflow {
					workflow_path = argument
					has_positional_workflow = true
				} else {
					return error('cli_argument_error: unknown argument `${argument}`')
				}
			}
		}
		cursor++
	}
	if command != .run && once {
		return error('cli_argument_error: --once is only valid with run')
	}
	return Options{
		command:       command
		workflow_path: workflow_path
		env_path:      env_path
		env_explicit:  env_explicit
		once:          once
		web_enabled:   web_enabled
		web_host:      web_host
		web_port:      web_port
	}
}

pub fn validate_workflow(path string) !workflow.WorkflowDefinition {
	definition := workflow.load(path, .syntax)!
	tracker.validate_adapter_config(definition.config.tracker)!
	prompt.render(definition.prompt_template, domain.Issue{
		id:          'validation-issue'
		identifier:  'SYM-VALIDATE'
		title:       'Validate workflow template'
		description: 'Template validation fixture'
		state:       'Todo'
		labels:      ['validation']
		blocked_by:  [
			domain.BlockerRef{
				id:         'validation-blocker'
				identifier: 'SYM-BLOCKER'
				state:      'Done'
			},
		]
	}, 1)!
	return definition
}

pub fn usage() string {
	return 'Usage: symphony [run|validate|doctor] [WORKFLOW_PATH] [--workflow PATH] [--env PATH] [--once] [--port PORT] [--web-host HOST]\n       symphony [version|help]'
}
