# Support

Use GitHub Issues for reproducible bugs and feature requests.

For launch or device problems, include:

- Windows version and monitor scale.
- Phone model and Android build.
- Root provider/version and whether the agent is approved.
- `adb devices -l` output with serials redacted if desired.
- `adb shell dumpsys window displays` for display geometry problems.
- `adb shell su -c "am stack list"` for app launch/task problems.
- The controller, agent, scrcpy client, and scrcpy server build timestamps.

Remove personal notification, task, and device data from diagnostics before
posting them publicly.
