package com.genymobile.scrcpy.compositor;

import android.graphics.Rect;
import android.hardware.display.VirtualDisplay;
import android.view.Surface;

import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.control.PositionMapper;
import com.genymobile.scrcpy.model.ConfigurationException;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.AffineMatrix;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.video.SurfaceCapture;
import com.genymobile.scrcpy.video.VideoConstraints;
import com.genymobile.scrcpy.video.VirtualDisplayListener;

import java.io.IOException;

/**
 * Experimental RewriteDEX task-only video source.
 *
 * WindowManager mirrors exactly one task hierarchy into a MediaCodec surface.
 * No full-display pixels are captured or cropped. The controller receives a
 * mapping back into the task's real display coordinates for direct input.
 */
public final class TaskSurfaceCapture extends SurfaceCapture {

    private final VirtualDisplayListener virtualDisplayListener;
    private final int requestedTaskId;

    private VideoConstraints videoConstraints;
    private Object taskInfo;
    private Rect taskBounds;
    private Size videoSize;
    private int taskDisplayId = -1;

    private Object mediaProjection;
    private VirtualDisplay virtualDisplay;

    public TaskSurfaceCapture(VirtualDisplayListener virtualDisplayListener, Options options) {
        this.virtualDisplayListener = virtualDisplayListener;
        this.requestedTaskId = options.getTaskId();
    }

    @Override
    protected void init(VideoConstraints videoConstraints) {
        this.videoConstraints = videoConstraints;
    }

    @Override
    public void prepare() throws ConfigurationException {
        try {
            taskInfo = TaskRecordingSnapshot.findTaskInfo(
                    TaskRecordingSnapshot.listTasks(),
                    requestedTaskId);
            if (taskInfo == null) {
                throw new ConfigurationException("Unknown task id: " + requestedTaskId);
            }
            taskBounds = TaskRecordingSnapshot.taskBounds(taskInfo);
            if (taskBounds.isEmpty()) {
                throw new ConfigurationException(
                        "Task " + requestedTaskId + " has empty bounds: " + taskBounds);
            }
            taskDisplayId = ((Number) TaskRecordingSnapshot.member(
                    taskInfo,
                    "getDisplayId",
                    "displayId")).intValue();
            videoSize = new Size(taskBounds.width(), taskBounds.height()).constrain(videoConstraints);
            Ln.i("Task compositor: task=" + requestedTaskId
                    + " display=" + taskDisplayId
                    + " bounds=" + taskBounds.flattenToString()
                    + " video=" + videoSize);
        } catch (ConfigurationException exception) {
            throw exception;
        } catch (Throwable throwable) {
            Throwable cause = throwable.getCause() != null ? throwable.getCause() : throwable;
            throw new ConfigurationException(
                    "Could not resolve task " + requestedTaskId + ": " + cause.getMessage());
        }
    }

    @Override
    public void start(Surface surface) throws IOException {
        stop();
        try {
            Object projectionManager = TaskRecordingSnapshot.mediaProjectionManager();
            Object activeProjection = TaskRecordingSnapshot.activeProjectionInfo(projectionManager);
            if (activeProjection != null) {
                throw new IllegalStateException(
                        "Another MediaProjection is active; refusing to replace it: " + activeProjection);
            }
            mediaProjection = TaskRecordingSnapshot.createMediaProjection(
                    projectionManager,
                    taskInfo,
                    requestedTaskId);
            virtualDisplay = TaskRecordingSnapshot.createRecordingDisplay(
                    "RewriteDEX-task-" + requestedTaskId,
                    videoSize.getWidth(),
                    videoSize.getHeight(),
                    surface,
                    mediaProjection);
            if (virtualDisplay == null || virtualDisplay.getDisplay() == null) {
                throw new IllegalStateException("WindowManager task recording display creation failed");
            }

            if (virtualDisplayListener != null) {
                double scaleX = (double) taskBounds.width() / videoSize.getWidth();
                double scaleY = (double) taskBounds.height() / videoSize.getHeight();
                AffineMatrix taskToDisplay = new AffineMatrix(
                        scaleX,
                        0,
                        0,
                        scaleY,
                        taskBounds.left,
                        taskBounds.top);
                PositionMapper mapper = new PositionMapper(videoSize, taskToDisplay);
                virtualDisplayListener.onNewVirtualDisplay(taskDisplayId, mapper);
            }

            Ln.i("Task compositor active: task=" + requestedTaskId
                    + " compositorDisplay=" + virtualDisplay.getDisplay().getDisplayId());
        } catch (Throwable throwable) {
            stop();
            Throwable cause = throwable.getCause() != null ? throwable.getCause() : throwable;
            throw new IOException(
                    "Could not start task compositor for task " + requestedTaskId + ": " + cause.getMessage(),
                    cause);
        }
    }

    @Override
    public void stop() {
        if (mediaProjection != null) {
            try {
                mediaProjection.getClass().getMethod("stop").invoke(mediaProjection);
            } catch (Throwable throwable) {
                Ln.w("Could not stop task MediaProjection cleanly");
            }
            mediaProjection = null;
        }
        if (virtualDisplay != null) {
            try {
                virtualDisplay.release();
            } catch (Throwable throwable) {
                Ln.w("Could not release task compositor display cleanly");
            }
            virtualDisplay = null;
        }
    }

    @Override
    public void release() {
        stop();
    }

    @Override
    public Size getSize() {
        return videoSize;
    }

    public int getTaskDisplayId() {
        return taskDisplayId;
    }

    @Override
    protected boolean applyNewVideoConstraints(VideoConstraints videoConstraints) {
        this.videoConstraints = videoConstraints;
        return true;
    }
}
