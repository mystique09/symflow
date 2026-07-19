module app

import os
import time
import symphony.dotenv
import symphony.observability
import symphony.orchestrator
import symphony.statusweb
import symphony.tracker
import symphony.workflow

pub const version = '0.1.0-dev'

struct DoctorCheck {
	name   string
	ok     bool
	detail string
}

pub fn execute(args []string) !int {
	options := parse_args(args)!
	load_command_environment(options)!
	match options.command {
		.help {
			println(usage())
			return 0
		}
		.version {
			println('symphony ${version}')
			return 0
		}
		.validate {
			definition := validate_workflow(options.workflow_path)!
			println('valid workflow: ${definition.path}')
			return 0
		}
		.doctor {
			checks := doctor(options.workflow_path)!
			mut healthy := true
			for check in checks {
				marker := if check.ok { 'ok' } else { 'error' }
				println('${marker}: ${check.name}: ${check.detail}')
				healthy = healthy && check.ok
			}
			return if healthy { 0 } else { 1 }
		}
		.run {
			run(options)!
			return 0
		}
	}
}

fn load_command_environment(options Options) ! {
	if options.command in [.run, .doctor, .validate] {
		dotenv.load(options.env_path, options.env_explicit)!
	}
}

fn run(options Options) ! {
	validate_workflow(options.workflow_path)!
	definition := workflow.load(options.workflow_path, .dispatch)!
	tracker.new_adapter(definition.config.tracker)!
	runtime := orchestrator.start_runtime(definition.config.agent.max_concurrent_agents,
		definition.config.agent.max_retry_backoff_ms)
	refresh := chan bool{cap: 1}
	shutdown := chan bool{cap: 1}
	web_stop := chan bool{cap: 1}
	web_done := chan string{cap: 1}
	configured_port := if options.web_port >= 0 {
		options.web_port
	} else if definition.config.server.port >= 0 {
		definition.config.server.port
	} else if options.web_enabled {
		8080
	} else {
		-1
	}
	web_enabled := configured_port >= 0
	if web_enabled {
		if options.web_host !in ['127.0.0.1', 'localhost', '::1'] {
			observability.emit(observability.Record{
				level:   'warn'
				event:   'statusweb_non_loopback_bind'
				message: 'status web is binding to ${options.web_host}'
			}, []string{})
		}
		spawn serve_web(runtime, refresh, web_stop, web_done, options.web_host, configured_port)
	}
	if !options.once {
		install_signal_handlers(shutdown)!
	}
	orchestrator.run_service(orchestrator.ServiceOptions{
		workflow_path: options.workflow_path
		once:          options.once
	}, runtime, refresh, shutdown) or {
		if web_enabled {
			web_stop <- true
			wait_for_web(web_done)
		}
		runtime.shutdown()
		return err
	}
	if web_enabled {
		web_stop <- true
		wait_for_web(web_done)
	}
	runtime.shutdown()
}

fn serve_web(runtime orchestrator.Runtime, refresh chan bool, stop chan bool, done chan string, host string, port int) {
	statusweb.serve(runtime, refresh, stop, statusweb.ServerConfig{
		host: host
		port: port
	}) or {
		eprintln('status web stopped with error: ${err.msg()}')
		done <- err.msg()
		return
	}
	done <- ''
}

fn wait_for_web(done chan string) {
	select {
		_ := <-done {}
		6 * time.second {
			eprintln('status web did not stop within 6 seconds')
		}
	}
}

fn install_signal_handlers(shutdown chan bool) ! {
	handler := fn [shutdown] (_ os.Signal) {
		select {
			shutdown <- true {}
			else {}
		}
	}
	os.signal_opt(.int, handler)!
	os.signal_opt(.term, handler)!
}

fn doctor(path string) ![]DoctorCheck {
	definition := validate_workflow(path)!
	mut checks := []DoctorCheck{}
	checks << DoctorCheck{
		name:   'workflow'
		ok:     true
		detail: definition.path
	}
	os.mkdir_all(definition.config.workspace.root) or {
		checks << DoctorCheck{
			name:   'workspace'
			detail: 'cannot create or access configured root'
		}
		return checks
	}
	checks << DoctorCheck{
		name:   'workspace'
		ok:     os.is_dir(definition.config.workspace.root)
		detail: definition.config.workspace.root
	}
	checks << DoctorCheck{
		name:   'shell'
		ok:     os.is_executable('/bin/bash')
		detail: '/bin/bash'
	}
	command_fields := definition.config.codex.command.fields()
	executable := if command_fields.len > 0 { command_fields[0] } else { '' }
	if absolute := os.find_abs_path_of_executable(executable) {
		checks << DoctorCheck{
			name:   'codex'
			ok:     true
			detail: absolute
		}
	} else {
		checks << DoctorCheck{
			name:   'codex'
			detail: 'executable `${executable}` was not found on PATH'
		}
	}
	tracker.new_adapter(definition.config.tracker) or {
		checks << DoctorCheck{
			name:   'tracker'
			detail: err.msg()
		}
		return checks
	}
	checks << DoctorCheck{
		name:   'tracker'
		ok:     true
		detail: '${definition.config.tracker.kind} adapter is configured'
	}
	return checks
}
