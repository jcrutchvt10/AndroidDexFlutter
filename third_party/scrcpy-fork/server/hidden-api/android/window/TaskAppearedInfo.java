package android.window;

import android.app.ActivityManager;
import android.view.SurfaceControl;

/**
 * Compile-only declaration for the hidden framework type.
 *
 * This class is deliberately excluded from scrcpy-server.dex. At runtime the
 * Android framework implementation from the boot class path is used.
 */
public final class TaskAppearedInfo {
    public ActivityManager.RunningTaskInfo getTaskInfo() {
        throw new UnsupportedOperationException("compile-time stub");
    }

    public SurfaceControl getLeash() {
        throw new UnsupportedOperationException("compile-time stub");
    }
}
