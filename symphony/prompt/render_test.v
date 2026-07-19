module prompt

import json2
import symphony.domain

fn prompt_issue() domain.Issue {
	return domain.Issue{
		id:           'opaque-1'
		identifier:   'OPS-1'
		title:        ' Repair Queue '
		description:  ''
		priority:     2
		state:        'Todo'
		labels:       ['Backend', 'Urgent']
		blocked_by:   [domain.BlockerRef{ identifier: 'OPS-2', state: 'In Progress' }]
		native_ref:   {
			'linear_issue_id': json2.Any('linear-1')
		}
		dispatchable: true
	}
}

fn test_render_exposes_provider_neutral_dispatch_and_native_reference_context() {
	result := render('{{ issue.dispatchable }} {{ issue.native_ref }}', prompt_issue(), 0) or {
		panic(err)
	}
	assert result == 'true {"linear_issue_id":"linear-1"}'
}

fn test_render_scalars_and_filters() {
	result := render('{{ issue.identifier }} {{ issue.title | trim | lower }} #{{ attempt }}',
		prompt_issue(), 3) or { panic(err) }
	assert result == 'OPS-1 repair queue #3'
}

fn test_default_filter_handles_missing_description_and_first_attempt() {
	result := render('{{ issue.description | default: "No description" }} / {{ attempt | default: "first" }}',
		prompt_issue(), -1) or { panic(err) }
	assert result == 'No description / first'
}

fn test_unknown_variable_and_filter_are_errors() {
	render('{{ issue.typo }}', prompt_issue(), 0) or {
		assert err.msg().contains('unknown variable')
		return
	}
	assert false, 'unknown variables must fail'
}

fn test_if_and_each_blocks_render_lists() {
	template := '{{#if issue.labels}}Labels:{{#each issue.labels}} [{{ this | lower }}]{{/each}}{{/if}} {{#each issue.blocked_by}}{{ this.identifier }}={{ this.state | lower }}{{/each}}'
	result := render(template, prompt_issue(), 0) or { panic(err) }
	assert result == 'Labels: [backend] [urgent] OPS-2=in progress'
}

fn test_false_if_block_is_omitted() {
	issue := domain.Issue{
		id:         '1'
		identifier: 'OPS-1'
		title:      'No labels'
		state:      'Todo'
	}
	assert render('A{{#if issue.labels}}nope{{/if}}B', issue, 0) or { panic(err) } == 'AB'
}

fn test_mismatched_blocks_include_position_context() {
	render('{{#if issue.labels}}x{{/each}}', prompt_issue(), 0) or {
		assert err.msg().contains('mismatched block')
		assert err.msg().contains('offset')
		return
	}
	assert false, 'mismatched blocks must fail'
}
