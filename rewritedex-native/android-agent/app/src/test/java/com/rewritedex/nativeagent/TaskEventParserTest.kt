package com.rewritedex.nativeagent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskEventParserTest {
    @Test
    fun parsesTaskAndDisplay() {
        assertEquals(
            TaskToFrontEvent(taskId = 573, displayId = 0),
            TaskEventParser.taskToFront("I/wm_task_to_front: [0,573,0]"),
        )
    }

    @Test
    fun ignoresOtherWindowManagerEvents() {
        assertNull(TaskEventParser.taskToFront("I/wm_task_moved: [573,573,2,1,1]"))
    }

    @Test
    fun parsesLauncherDesktopTarget() {
        assertEquals(
            "org.joa.zipperplus7/org.joa.zipperplus7.StartPageActivity",
            TaskEventParser.desktopTargetComponent(
                "D/TaskbarActivityContext: targetComponent=ComponentInfo{" +
                    "org.joa.zipperplus7/org.joa.zipperplus7.StartPageActivity}",
            ),
        )
    }

    @Test
    fun ignoresUnrelatedLauncherLogs() {
        assertNull(TaskEventParser.desktopTargetComponent("D/TaskbarActivityContext: taskbar opened"))
        assertNull(
            TaskEventParser.desktopTargetComponent(
                "D/TaskbarActivityContext: targetComponent=ComponentInfo{missing-end",
            ),
        )
    }

    @Test
    fun parsesLauncherStartActivityCmp() {
        assertEquals(
            "com.android.settings/com.android.settings.Settings",
            TaskEventParser.desktopTargetComponent(
                "I/Launcher: startActivity cmp=com.android.settings/com.android.settings.Settings",
            ),
        )
    }

    @Test
    fun parsesActivityTaskManagerStartCmp() {
        assertEquals(
            "com.android.settings/com.android.settings.Settings",
            TaskEventParser.desktopTargetComponent(
                "I/ActivityTaskManager: START u0 {act=android.intent.action.MAIN " +
                    "cat=[android.intent.category.LAUNCHER] cmp=com.android.settings/com.android.settings.Settings} " +
                    "from uid 10143",
            ),
        )
    }

    @Test
    fun ignoresCmpOutsideLaunchContext() {
        assertNull(
            TaskEventParser.desktopTargetComponent(
                "D/PackageManager: resolved cmp=com.android.settings/com.android.settings.Settings",
            ),
        )
    }
}
