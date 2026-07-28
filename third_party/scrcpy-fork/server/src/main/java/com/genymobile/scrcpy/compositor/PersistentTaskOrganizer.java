package com.genymobile.scrcpy.compositor;

import android.app.ActivityManager;
import android.graphics.Rect;
import android.view.SurfaceControl;
import android.window.TaskAppearedInfo;
import android.window.TaskOrganizer;

import com.genymobile.scrcpy.util.Ln;

import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The one TaskOrganizer owned by the RewriteDEX compositor broker.
 *
 * Task leashes are valid only while this organizer remains registered. Encoder
 * sessions borrow a record, create their own mirror hierarchy, and never
 * register another organizer.
 */
final class PersistentTaskOrganizer extends TaskOrganizer {

    static final class TaskRecord {
        private volatile ActivityManager.RunningTaskInfo taskInfo;
        private final SurfaceControl leash;
        private final CopyOnWriteArrayList<BrokerMirrorCapture> captures =
                new CopyOnWriteArrayList<>();
        private volatile boolean alive = true;

        TaskRecord(ActivityManager.RunningTaskInfo taskInfo, SurfaceControl leash) {
            this.taskInfo = taskInfo;
            this.leash = leash;
        }

        int getTaskId() {
            return taskInfo.taskId;
        }

        int getDisplayId() {
            try {
                return ((Number) TaskRecordingSnapshot.member(
                        taskInfo,
                        "getDisplayId",
                        "displayId")).intValue();
            } catch (Exception exception) {
                return -1;
            }
        }

        Rect getBounds() throws Exception {
            return TaskRecordingSnapshot.taskBounds(taskInfo);
        }

        SurfaceControl getLeash() {
            return leash;
        }

        boolean isAlive() {
            return alive && leash.isValid();
        }

        void addCapture(BrokerMirrorCapture capture) {
            captures.add(capture);
        }

        void removeCapture(BrokerMirrorCapture capture) {
            captures.remove(capture);
        }

        void update(ActivityManager.RunningTaskInfo info) {
            Rect previousBounds = null;
            int previousDisplayId = getDisplayId();
            try {
                previousBounds = getBounds();
            } catch (Exception exception) {
                Ln.w("Could not read previous task bounds for " + getTaskId());
            }
            taskInfo = info;
            boolean geometryChanged = previousDisplayId != getDisplayId();
            try {
                geometryChanged |= previousBounds == null
                        || !previousBounds.equals(getBounds());
            } catch (Exception exception) {
                geometryChanged = true;
            }
            if (geometryChanged) {
                for (BrokerMirrorCapture capture : captures) {
                    capture.onTaskInfoChanged();
                }
            }
        }

        void vanish() {
            alive = false;
            for (BrokerMirrorCapture capture : captures) {
                capture.onTaskVanished();
            }
            captures.clear();
            leash.release();
        }
    }

    private final ConcurrentHashMap<Integer, TaskRecord> tasks =
            new ConcurrentHashMap<>();

    void registerOnce() {
        List<TaskAppearedInfo> initialTasks = registerOrganizer();
        for (TaskAppearedInfo appeared : initialTasks) {
            remember(appeared.getTaskInfo(), appeared.getLeash());
        }
        Ln.i("RewriteDEX compositor organizer registered with "
                + tasks.size() + " task leashes");
    }

    TaskRecord getTask(int taskId) {
        TaskRecord record = tasks.get(taskId);
        return record != null && record.isAlive() ? record : null;
    }

    int getTaskCount() {
        return tasks.size();
    }

    @Override
    public void onTaskAppeared(
            ActivityManager.RunningTaskInfo taskInfo,
            SurfaceControl leash) {
        remember(taskInfo, leash);
    }

    @Override
    public void onTaskInfoChanged(ActivityManager.RunningTaskInfo taskInfo) {
        TaskRecord record = tasks.get(taskInfo.taskId);
        if (record != null) {
            record.update(taskInfo);
        }
    }

    @Override
    public void onTaskVanished(ActivityManager.RunningTaskInfo taskInfo) {
        TaskRecord record = tasks.remove(taskInfo.taskId);
        if (record != null) {
            Ln.i("RewriteDEX compositor task vanished: " + taskInfo.taskId);
            record.vanish();
        }
    }

    void releaseAll() {
        try {
            unregisterOrganizer();
        } catch (Throwable throwable) {
            Ln.w("Could not unregister RewriteDEX compositor organizer");
        }
        for (TaskRecord record : tasks.values()) {
            record.vanish();
        }
        tasks.clear();
    }

    private void remember(
            ActivityManager.RunningTaskInfo taskInfo,
            SurfaceControl leash) {
        showLeash(leash);
        TaskRecord replacement = new TaskRecord(taskInfo, leash);
        TaskRecord old = tasks.put(taskInfo.taskId, replacement);
        if (old != null) {
            old.vanish();
        }
        Ln.i("RewriteDEX compositor task appeared: task=" + taskInfo.taskId
                + " display=" + replacement.getDisplayId());
    }

    private static void showLeash(SurfaceControl leash) {
        try {
            Class<?> transactionClass =
                    Class.forName("android.view.SurfaceControl$Transaction");
            Object transaction = transactionClass.getDeclaredConstructor().newInstance();
            transactionClass.getMethod(
                    "show",
                    SurfaceControl.class).invoke(transaction, leash);
            transactionClass.getMethod("apply").invoke(transaction);
        } catch (Throwable throwable) {
            Ln.w("Could not show organized task leash");
        }
    }
}
