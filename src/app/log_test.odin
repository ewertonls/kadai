#+test
package app

import "base:runtime"
import "core:testing"
import "core:time"
import "kadai:yaml"

@(test)
log_errors_survive_unavailable_scratch_memory :: proc(t: ^testing.T) {
	diagnostic := yaml.Diagnostic{path = "a.md", code = "invalid_log", message = "Close the log.", location = {line = 7}}
	allocation_issue, document_issue, timestamp, time_issue: string
	{
		context.temp_allocator = runtime.nil_allocator()
		allocation_issue = log_issue(runtime.Allocator_Error.Out_Of_Memory)
		document_issue = log_issue(diagnostic)
		timestamp, time_issue = log_timestamp(time.unix(0, 0), "")
	}
	testing.expect(t, allocation_issue != "" && document_issue != "")
	testing.expect(t, timestamp == "" && time_issue != "")
}

@(test)
log_timestamps_use_the_offset_at_the_instant :: proc(t: ^testing.T) {
	for c in ([]struct {utc, zone, expected: string}{
		{"2026-07-01T22:20:03Z", "Asia/Kathmandu", "2026-07-02T04:05:03+05:45"},
		{"2026-03-08T06:59:59Z", "America/New_York", "2026-03-08T01:59:59-05:00"},
		{"2026-03-08T07:00:00Z", "America/New_York", "2026-03-08T03:00:00-04:00"},
		// Beyond the last explicit transition in many TZif tables, the region
		// supplies recurring rules. Windows supplies those rules for all years.
		{"2040-03-11T06:59:59Z", "America/New_York", "2040-03-11T01:59:59-05:00"},
		{"2040-03-11T07:00:00Z", "America/New_York", "2040-03-11T03:00:00-04:00"},
		{"2026-07-01T00:00:00Z", "UTC", "2026-07-01T00:00:00+00:00"},
	}) {
		instant, n := time.rfc3339_to_time_utc(c.utc)
		if !testing.expect_value(t, n, len(c.utc)) do continue
		stamp, issue := log_timestamp(instant, c.zone)
		if testing.expect_value(t, issue, "") do testing.expect_value(t, stamp, c.expected)
	}
}
