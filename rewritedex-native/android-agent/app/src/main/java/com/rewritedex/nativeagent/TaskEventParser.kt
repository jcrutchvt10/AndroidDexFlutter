package com.rewritedex.nativeagent

data class TaskToFrontEvent(val taskId: Int, val displayId: Int)

object TaskEventParser {
    // AOSP events buffer formats vary slightly across Android releases.
    private val taskToFrontPattern = Regex(
        "wm_task_to_front:\\s*\\[\\d+,(\\d+),(\\d+)]",
    )
    private const val DESKTOP_TARGET_PREFIX = "targetComponent=ComponentInfo{"
    // App drawer / icon launch logs often use cmp= rather than targetComponent.
    private val cmpPattern = Regex("""\bcmp=([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+)""")

    fun taskToFront(line: String): TaskToFrontEvent? {
        val match = taskToFrontPattern.find(line) ?: return null
        return TaskToFrontEvent(
            taskId = match.groupValues[1].toInt(),
            displayId = match.groupValues[2].toInt(),
        )
    }

    fun desktopTargetComponent(line: String): String? {
        val start = line.indexOf(DESKTOP_TARGET_PREFIX)
        if (start >= 0) {
            val componentStart = start + DESKTOP_TARGET_PREFIX.length
            val end = line.indexOf('}', componentStart)
            if (end > componentStart) return line.substring(componentStart, end)
        }
        // Only treat cmp= as a desktop launch hint when the line looks like a
        // launcher/activity start, not an arbitrary binder dump.
        if (line.contains("startActivity", ignoreCase = true) ||
            line.contains("ActivityTaskManager") ||
            line.contains("TaskbarActivityContext") ||
            line.contains("Launcher") ||
            line.contains("BubbleTextView")
        ) {
            return cmpPattern.find(line)?.groupValues?.get(1)
        }
        return null
    }
}
