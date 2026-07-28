package com.rewritedex.nativeagent

data class ParsedTaskBounds(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
)

data class ParsedDesktopTask(
    val rootTaskId: Int,
    val taskId: Int,
    val displayId: Int,
    val packageName: String,
    val component: String,
    val bounds: ParsedTaskBounds,
    val visible: Boolean,
)

object DesktopTaskParser {
    private val displayPattern = Regex("displayId=(\\d+)")
    private val rootTaskPattern = Regex("RootTask id=(\\d+)")
    private val taskPattern = Regex(
        "taskId=(\\d+):\\s+([^\\s]+)\\s+bounds=\\[(-?\\d+),(-?\\d+)]\\[(-?\\d+),(-?\\d+)]" +
            ".*visible=(true|false)",
    )

    fun parse(output: String): List<ParsedDesktopTask> {
        val tasks = mutableListOf<ParsedDesktopTask>()
        var displayId = 0
        var rootTaskId = -1
        output.lineSequence().forEach { line ->
            if (line.startsWith("RootTask")) {
                rootTaskId = rootTaskPattern.find(line)?.groupValues?.get(1)?.toIntOrNull() ?: -1
                displayId = displayPattern.find(line)?.groupValues?.get(1)?.toIntOrNull() ?: 0
            }
            val match = taskPattern.find(line.trim()) ?: return@forEach
            val component = match.groupValues[2]
            if (rootTaskId < 0 || component == "unknown" || !component.contains('/')) return@forEach
            tasks += ParsedDesktopTask(
                rootTaskId = rootTaskId,
                taskId = match.groupValues[1].toInt(),
                displayId = displayId,
                packageName = component.substringBefore('/'),
                component = component,
                bounds = ParsedTaskBounds(
                    match.groupValues[3].toInt(),
                    match.groupValues[4].toInt(),
                    match.groupValues[5].toInt(),
                    match.groupValues[6].toInt(),
                ),
                visible = match.groupValues[7].toBoolean(),
            )
        }
        return tasks
    }
}

/**
 * Fallback parser for `dumpsys activity activities` output on newer Android
 * builds where `am stack list` has been removed. Best-effort: tracks task IDs,
 * display IDs, bounds, and activity components across multiple AOSP layout versions.
 */
object DumpsysActivitiesParser {
    private val taskIdPattern = Regex("(?:Task id #|Task\\{[^#]*#)(\\d+)")
    private val displayPattern = Regex("displayId=(\\d+)")
    private val boundsPattern = Regex("bounds=\\[(-?\\d+),(-?\\d+)\\]\\[(-?\\d+),(-?\\d+)\\]")
    private val componentPattern = Regex("(?:mActivityComponent|baseIntent=.*cmp)=([^\\s}]+)")
    private val activityRecordPattern = Regex("ActivityRecord\\{[^}]+\\s+([^\\s]+)/([^\\s]+)\\s+t(\\d+)")

    fun parse(output: String): List<ParsedDesktopTask> {
        val tasks = mutableListOf<ParsedDesktopTask>()
        val blocks = mutableListOf<MutableMap<String, String>>()
        var currentBlock = mutableMapOf<String, String>()
        var indentLevel = 0

        fun emitBlock() {
            if (currentBlock.isNotEmpty()) blocks.add(currentBlock)
            currentBlock = mutableMapOf()
        }

        output.lineSequence().forEach { raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("*")) {
                emitBlock()
                return@forEach
            }

            val taskMatch = taskIdPattern.find(line)
            if (taskMatch != null) {
                emitBlock()
                currentBlock["taskId"] = taskMatch.groupValues[1]
            }
            displayPattern.find(line)?.let { currentBlock["displayId"] = it.groupValues[1] }
            boundsPattern.find(line)?.let {
                currentBlock["left"] = it.groupValues[1]
                currentBlock["top"] = it.groupValues[2]
                currentBlock["right"] = it.groupValues[3]
                currentBlock["bottom"] = it.groupValues[4]
            }
            componentPattern.find(line)?.let { currentBlock["component"] = it.groupValues[1] }
            activityRecordPattern.find(line)?.let {
                currentBlock["component"] = "${it.groupValues[1]}/${it.groupValues[2]}"
                currentBlock["taskId"] = it.groupValues[3]
            }
            if (line.contains("visible=true", ignoreCase = true)) currentBlock["visible"] = "true"
            if (line.contains("visible=false", ignoreCase = true)) currentBlock["visible"] = "false"
            if (line.contains("isVisible=true", ignoreCase = true)) currentBlock["visible"] = "true"
        }
        emitBlock()

        val seen = mutableSetOf<Int>()
        for (block in blocks) {
            val taskId = block["taskId"]?.toIntOrNull() ?: continue
            if (taskId in seen) continue
            val component = block["component"] ?: continue
            if (!component.contains('/')) continue
            val displayId = block["displayId"]?.toIntOrNull() ?: 0
            val left = block["left"]?.toIntOrNull() ?: 0
            val top = block["top"]?.toIntOrNull() ?: 0
            val right = block["right"]?.toIntOrNull() ?: left
            val bottom = block["bottom"]?.toIntOrNull() ?: top
            val visible = block["visible"]?.toBoolean() ?: true
            tasks += ParsedDesktopTask(
                rootTaskId = taskId,
                taskId = taskId,
                displayId = displayId,
                packageName = component.substringBefore('/'),
                component = component,
                bounds = ParsedTaskBounds(left, top, right, bottom),
                visible = visible,
            )
            seen += taskId
        }
        return tasks
    }
}
