package app

import win "core:sys/windows"
import "core:time"

@(private)
local_log_offset :: proc(instant: time.Time) -> (seconds: i64, ok: bool) {
	dt := time.time_to_datetime(instant) or_return
	utc := win.SYSTEMTIME {
		year   = u16(dt.year),
		month  = u16(dt.month),
		day    = u16(dt.day),
		hour   = u16(dt.hour),
		minute = u16(dt.minute),
		second = u16(dt.second),
	}
	local: win.SYSTEMTIME
	// nil uses the machine's effective zone, including disabled DST adjustments.
	if !win.SystemTimeToTzSpecificLocalTime(nil, &utc, &local) do return 0, false
	wall := time.datetime_to_time(
		local.year,
		local.month,
		local.day,
		local.hour,
		local.minute,
		local.second,
	) or_return
	return time.to_unix_seconds(wall) - time.to_unix_seconds(instant), true
}
