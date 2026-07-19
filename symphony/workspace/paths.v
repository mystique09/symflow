module workspace

import crypto.sha256
import os
import strings
import symphony.workflow

pub struct Workspace {
pub:
	root        string
	path        string
	key         string
	created_now bool
}

pub fn workspace_key(identifier string) string {
	mut builder := strings.new_builder(identifier.len)
	for value in identifier.bytes() {
		if (value >= `A` && value <= `Z`) || (value >= `a` && value <= `z`)
			|| (value >= `0` && value <= `9`) || value in [u8(`.`), `-`, `_`] {
			builder.write_u8(value)
		} else {
			builder.write_u8(`_`)
		}
	}
	mut sanitized := builder.str()
	if sanitized == '' {
		sanitized = 'issue'
	}
	changed := sanitized != identifier || sanitized.len > 160
	if !changed {
		return sanitized
	}
	if sanitized.len > 120 {
		sanitized = sanitized[..120]
	}
	return '${sanitized}-${sha256.hexhash(identifier)[..16]}'
}

pub fn validate_under_root(root string, candidate string) !string {
	canonical_root := os.real_path(root)
	canonical_candidate := os.real_path(candidate)
	prefix := canonical_root.trim_right(os.path_separator) + os.path_separator
	if canonical_candidate == canonical_root || !canonical_candidate.starts_with(prefix) {
		return error('workspace_escape: `${canonical_candidate}` is not a child of the configured workspace root')
	}
	return canonical_candidate
}

pub fn path_for(root string, identifier string) !string {
	if identifier.trim_space() == '' {
		return error('workspace_identifier_error: issue identifier must not be blank')
	}
	return validate_under_root(root, os.join_path(root, workspace_key(identifier)))
}

pub fn prepare(root string, identifier string, hooks workflow.HooksConfig) !Workspace {
	cancel := chan bool{}
	return prepare_cancelable(root, identifier, hooks, cancel)
}

pub fn prepare_cancelable(root string, identifier string, hooks workflow.HooksConfig, cancel chan bool) !Workspace {
	return prepare_cancelable_sanitized(root, identifier, hooks, []string{}, cancel)
}

pub fn prepare_cancelable_sanitized(root string, identifier string, hooks workflow.HooksConfig, secret_environment_names []string, cancel chan bool) !Workspace {
	os.mkdir_all(root) or {
		return error('workspace_create_error: unable to create workspace root')
	}
	canonical_root := os.real_path(root)
	path := path_for(canonical_root, identifier)!
	mut created_now := false
	if os.exists(path) {
		if !os.is_dir(path) {
			return error('workspace_create_error: workspace path exists but is not a directory')
		}
		validate_under_root(canonical_root, path)!
	} else {
		os.mkdir_all(path) or {
			return error('workspace_create_error: unable to create issue workspace')
		}
		created_now = true
	}
	space := Workspace{
		root:        canonical_root
		path:        path
		key:         workspace_key(identifier)
		created_now: created_now
	}
	if created_now && hooks.after_create.trim_space() != '' {
		run_hook_cancelable_sanitized(hooks.after_create, path, hooks.timeout_ms,
			default_hook_output_limit, secret_environment_names, cancel) or {
			safely_remove_workspace_path(canonical_root, path) or {}
			return error('after_create_hook_error: ${err.msg()}')
		}
	}
	return space
}

pub fn remove(space Workspace, hooks workflow.HooksConfig) ![]string {
	return remove_sanitized(space, hooks, []string{})
}

pub fn remove_sanitized(space Workspace, hooks workflow.HooksConfig, secret_environment_names []string) ![]string {
	mut warnings := []string{}
	path := validate_under_root(space.root, space.path)!
	if !os.exists(path) {
		return warnings
	}
	if hooks.before_remove.trim_space() != '' {
		run_hook_sanitized(hooks.before_remove, path, hooks.timeout_ms, default_hook_output_limit,
			secret_environment_names) or { warnings << 'before_remove_hook_error: ${err.msg()}' }
	}
	safely_remove_workspace_path(space.root, path) or {
		return error('workspace_remove_error: unable to remove issue workspace')
	}
	return warnings
}

fn safely_remove_workspace_path(root string, path string) ! {
	canonical_root := os.real_path(root)
	canonical_parent := os.real_path(os.dir(path))
	if canonical_parent != canonical_root {
		return error('workspace_escape: workspace parent changed before removal')
	}
	if os.is_link(path) {
		os.rm(path)!
		return
	}
	validated := validate_under_root(canonical_root, path)!
	os.rmdir_all(validated)!
}
