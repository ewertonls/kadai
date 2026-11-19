#+build darwin, linux
package app

import "core:sys/posix"
import "core:time"

@(private)
local_log_offset :: proc(instant: time.Time) -> (i64, bool) {
	// libc handles both TZ and /etc/localtime, including a plain TZif file.
	epoch := posix.time_t(time.to_unix_seconds(instant))
	local: posix.tm
	if posix.localtime_r(&epoch, &local) == nil do return 0, false
	return i64(local.tm_gmtoff), true
}
