package app

import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/timezone"

@(private)
log_offset :: proc(instant: time.Time, name: string) -> (seconds: i64, ok: bool) {
	if name == "" do return local_log_offset(instant)
	region, loaded := timezone.region_load(name, context.temp_allocator)
	if !loaded do return
	defer timezone.region_destroy(region, context.temp_allocator)
	if region == nil do return 0, true // UTC

	epoch := time.to_unix_seconds(instant)
	if len(region.records) > 0 && epoch <= region.records[len(region.records)-1].time {
		// The new offset takes effect at the transition second itself.
		#reverse for record in region.records {
			if epoch >= record.time do return record.utc_offset, true
		}
		return region.records[0].utc_offset, true
	}
	if !region.rrule.has_dst do return region.rrule.std_offset, true

	// Odin compares recurring transition times against UTC. The TZif and
	// Windows rules express each transition in the wall time *before* it.
	region.rrule.std_date.time -= region.rrule.std_offset
	region.rrule.dst_date.time -= region.rrule.dst_offset
	utc := time.time_to_datetime(instant) or_return
	local := timezone.datetime_to_tz(utc, region) or_return
	wall := time.datetime_to_time(local) or_return
	return i64(time.diff(instant, wall) / time.Second), true
}

@(private)
log_timestamp :: proc(instant: time.Time, name: string) -> (string, string) {
	offset, ok := log_offset(instant, name)
	if !ok || offset % 60 != 0 || abs(offset) >= 24 * 60 * 60 {
		reason :: "cannot determine a minute-precision UTC offset"
		zone := name if name != "" else "local"
		message, err := strings.concatenate({reason, " for time zone ", zone}, context.temp_allocator)
		if err != nil || message == "" do return "", reason
		return "", message
	}
	local, valid := time.time_to_datetime(time.time_add(instant, time.Duration(offset) * time.Second))
	if !valid do return "", "cannot represent the current time"
	minutes := abs(offset) / 60
	sign := '-' if offset < 0 else '+'
	stamp := fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d", local.year, local.month, local.day,
	                     local.hour, local.minute, local.second, sign, minutes / 60, minutes % 60)
	if len(stamp) != len("2000-01-01T00:00:00+00:00") do return "", "cannot format task log timestamp"
	return stamp, ""
}
