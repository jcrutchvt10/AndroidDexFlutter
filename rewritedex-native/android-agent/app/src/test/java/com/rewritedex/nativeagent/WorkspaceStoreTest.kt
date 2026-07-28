package com.rewritedex.nativeagent

import org.junit.Assert.assertEquals
import org.junit.Test

class WorkspaceStoreTest {
    @Test fun acceptsHumanWorkspaceNames() {
        assertEquals("Work 1", WorkspaceStore.requireName("Work 1"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsNamesThatCouldEscapeStorageKeys() {
        WorkspaceStore.requireName("../../bad")
    }
}
