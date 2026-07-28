package com.rewritedex.nativeagent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopTaskParserTest {
    @Test
    fun parsesTasksAcrossDisplays() {
        val output = """
            RootTask id=559 bounds=[0,0][1920,1008] displayId=21 userId=0
              taskId=559: com.example.app/com.example.app.MainActivity bounds=[40,50][1240,850] userId=0 visible=true
            RootTask id=1 bounds=[0,0][1344,2992] displayId=0 userId=0
              taskId=12: com.example.phone/.PhoneActivity bounds=[0,0][1344,2992] userId=0 visible=false
        """.trimIndent()

        val tasks = DesktopTaskParser.parse(output)

        assertEquals(2, tasks.size)
        assertEquals(21, tasks[0].displayId)
        assertEquals("com.example.app", tasks[0].packageName)
        assertEquals(ParsedTaskBounds(40, 50, 1240, 850), tasks[0].bounds)
        assertTrue(tasks[0].visible)
        assertEquals(0, tasks[1].displayId)
        assertFalse(tasks[1].visible)
    }

    @Test
    fun ignoresUnknownAndOrphanTasks() {
        val output = """
              taskId=2: com.orphan/.Main bounds=[0,0][100,100] userId=0 visible=true
            RootTask id=3 bounds=[0,0][1344,2992] displayId=0 userId=0
              taskId=0: unknown bounds=[0,0][1344,2992] userId=0 visible=false
              taskId=4: com.valid/.Main bounds=[-10,20][900,1200] userId=0 visible=true
        """.trimIndent()

        val tasks = DesktopTaskParser.parse(output)

        assertEquals(1, tasks.size)
        assertEquals(4, tasks.single().taskId)
        assertEquals(-10, tasks.single().bounds.left)
    }
}
