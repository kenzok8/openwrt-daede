#!/bin/sh
# Refresh the package index in the background so the Updates view reflects newly
# released versions without the user running `apk update` elsewhere. Returns
# immediately; the next poll cycle reads the refreshed index. Throttled to avoid
# hammering the feeds on repeated page loads.

LOCK=/tmp/luci-app-daede.idx.lock

if [ -f "$LOCK" ]; then
	mtime=$(date -r "$LOCK" +%s 2>/dev/null || echo 0)
	[ "$(( $(date +%s) - mtime ))" -lt 90 ] && exit 0
fi
: > "$LOCK"

(
	if command -v apk >/dev/null 2>&1; then
		apk update
	elif command -v opkg >/dev/null 2>&1; then
		opkg update
	fi
) >/dev/null 2>&1 </dev/null &

exit 0
