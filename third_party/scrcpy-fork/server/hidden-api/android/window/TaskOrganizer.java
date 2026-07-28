package android.window;

import android.app.ActivityManager;
import android.view.SurfaceControl;

import java.util.List;

/**
 * Compile-only declaration for the hidden framework type.
 *
 * The build keeps this stub on javac/d8's class path but never packages it.
 */
public class TaskOrganizer {
    public TaskOrganizer() {
    }

    public List<TaskAppearedInfo> registerOrganizer() {
        throw new UnsupportedOperationException("compile-time stub");
    }

    public void unregisterOrganizer() {
        throw new UnsupportedOperationException("compile-time stub");
    }

    public void onTaskAppeared(
            ActivityManager.RunningTaskInfo taskInfo,
            SurfaceControl leash) {
    }

    public void onTaskVanished(ActivityManager.RunningTaskInfo taskInfo) {
    }

    public void onTaskInfoChanged(ActivityManager.RunningTaskInfo taskInfo) {
    }
}
