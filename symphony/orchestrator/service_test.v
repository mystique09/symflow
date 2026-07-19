module orchestrator

import os
import time
import yaml
import symphony.domain
import symphony.tracker
import symphony.workflow

fn test_successful_file_outcome_releases_claim_without_continuation() {
	dir := service_file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	ticket_path := os.join_path(dir, 'SYM-400.md')
	os.write_file(ticket_path,
		'---\nschema_version: 1\nid: "opaque-400"\nidentifier: SYM-400\ntitle: "Do local work"\nstate: Todo\ndispatch_status: pending\nlast_error: ""\ncompleted_at: ""\n---\n\nWork locally.\n')!
	definition := workflow.WorkflowDefinition{
		config: workflow.Config{
			tracker: workflow.TrackerConfig{
				kind:     'file'
				provider: {
					'root': yaml.Any(dir)
				}
			}
			agent:   workflow.AgentConfig{
				max_concurrent_agents: 1
				max_retry_backoff_ms:  300_000
			}
		}
	}
	client := tracker.new_adapter(definition.config.tracker)!
	issue := client.fetch_issues_by_states(['Todo'])![0]
	runtime := start_runtime(1, 300_000)
	defer {
		runtime.shutdown()
	}
	assert runtime.claim(issue, 0, 1_000)
	mut cancellations := map[string]chan bool{}
	mut remove_after_finish := map[string]bool{}

	handle_worker_event(definition, runtime, WorkerEvent{
		issue:   issue
		outcome: domain.AttemptOutcome{
			kind:     .succeeded
			issue_id: issue.id
		}
	}, mut cancellations, mut remove_after_finish)

	snapshot := runtime.snapshot(2_000)
	assert snapshot.running.len == 0
	assert snapshot.retrying.len == 0
	assert os.read_file(ticket_path)!.contains('dispatch_status: completed')
}

fn service_file_tracker_test_dir() string {
	path := os.join_path(os.temp_dir(),
		'symphony-service-file-tracker-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}
