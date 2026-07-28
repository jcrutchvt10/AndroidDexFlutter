#!/system/bin/sh

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

uid=""
attempt=0
while [ -z "$uid" ] && [ "$attempt" -lt 30 ]; do
    uid="$(cmd package list packages -U com.rewritedex.nativeagent 2>/dev/null | sed -n 's/.* uid://p' | head -n 1)"
    [ -z "$uid" ] && sleep 2
    attempt=$((attempt + 1))
done

if [ -n "$uid" ]; then
    pm grant com.rewritedex.nativeagent android.permission.READ_LOGS 2>/dev/null
fi
