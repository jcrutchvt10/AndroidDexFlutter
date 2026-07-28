package com.genymobile.scrcpy.compositor;

import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.view.Surface;
import android.view.SurfaceControl;

import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.model.ConfigurationException;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.video.CaptureControl;
import com.genymobile.scrcpy.video.SurfaceCapture;
import com.genymobile.scrcpy.video.VideoConstraints;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import java.io.IOException;
import java.lang.reflect.Method;

/**
 * Mirrors one persistent TaskOrganizer leash into one encoder Surface.
 */
final class BrokerMirrorCapture extends SurfaceCapture {

    private final PersistentTaskOrganizer.TaskRecord task;

    private VideoConstraints constraints;
    private Rect sourceBounds;
    private Size videoSize;
    private VirtualDisplay virtualDisplay;
    private Object container;
    private Object mirror;
    private Object transaction;
    private volatile boolean closed;

    BrokerMirrorCapture(PersistentTaskOrganizer.TaskRecord task) {
        this.task = task;
    }

    @Override
    protected void init(VideoConstraints videoConstraints) {
        constraints = videoConstraints;
        task.addCapture(this);
    }

    @Override
    public void prepare() throws ConfigurationException {
        if (!task.isAlive()) {
            throw new ConfigurationException("Task " + task.getTaskId() + " vanished");
        }
        try {
            sourceBounds = task.getBounds();
        } catch (Exception exception) {
            throw new ConfigurationException(
                    "Could not read task " + task.getTaskId() + " bounds");
        }
        if (sourceBounds.isEmpty()) {
            throw new ConfigurationException(
                    "Task " + task.getTaskId() + " has empty bounds");
        }
        videoSize = new Size(
                sourceBounds.width(),
                sourceBounds.height()).constrain(constraints);
    }

    @Override
    public void start(Surface surface) throws IOException {
        stop();
        try {
            int flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY;
            virtualDisplay = ServiceManager.getDisplayManager().createNewVirtualDisplay(
                    "RewriteDEX-broker-task-" + task.getTaskId(),
                    videoSize.getWidth(),
                    videoSize.getHeight(),
                    320,
                    surface,
                    flags);
            if (virtualDisplay == null || virtualDisplay.getDisplay() == null) {
                throw new IllegalStateException("Could not create broker compositor display");
            }
            DisplayInfo displayInfo = ServiceManager.getDisplayManager().getDisplayInfo(
                    virtualDisplay.getDisplay().getDisplayId());
            if (displayInfo == null) {
                throw new IllegalStateException("Could not resolve broker compositor display");
            }

            Class<?> surfaceControlClass = Class.forName("android.view.SurfaceControl");
            Class<?> builderClass = Class.forName("android.view.SurfaceControl$Builder");
            Object builder = builderClass.getDeclaredConstructor().newInstance();
            builder = builderClass.getMethod("setName", String.class).invoke(
                    builder,
                    "RewriteDEX-task-container-" + task.getTaskId());
            builder = builderClass.getMethod("setContainerLayer").invoke(builder);
            container = builderClass.getMethod("build").invoke(builder);

            Method mirrorSurface = surfaceControlClass.getMethod(
                    "mirrorSurface",
                    surfaceControlClass);
            mirror = mirrorSurface.invoke(null, task.getLeash());

            Class<?> transactionClass =
                    Class.forName("android.view.SurfaceControl$Transaction");
            transaction = transactionClass.getDeclaredConstructor().newInstance();
            transactionClass.getMethod(
                    "setLayerStack",
                    surfaceControlClass,
                    int.class).invoke(
                            transaction,
                            container,
                            displayInfo.getLayerStack());
            transactionClass.getMethod(
                    "reparent",
                    surfaceControlClass,
                    surfaceControlClass).invoke(
                            transaction,
                            mirror,
                            container);
            transactionClass.getMethod(
                    "setPosition",
                    surfaceControlClass,
                    float.class,
                    float.class).invoke(
                            transaction,
                            mirror,
                            0f,
                            0f);
            transactionClass.getMethod(
                    "setCrop",
                    surfaceControlClass,
                    Rect.class).invoke(
                            transaction,
                            mirror,
                            new Rect(0, 0, sourceBounds.width(), sourceBounds.height()));
            transactionClass.getMethod(
                    "setScale",
                    surfaceControlClass,
                    float.class,
                    float.class).invoke(
                            transaction,
                            mirror,
                            (float) videoSize.getWidth() / sourceBounds.width(),
                            (float) videoSize.getHeight() / sourceBounds.height());
            transactionClass.getMethod(
                    "setLayer",
                    surfaceControlClass,
                    int.class).invoke(
                            transaction,
                            mirror,
                            1);
            transactionClass.getMethod(
                    "show",
                    surfaceControlClass).invoke(transaction, mirror);
            transactionClass.getMethod(
                    "show",
                    surfaceControlClass).invoke(transaction, container);
            transactionClass.getMethod("apply").invoke(transaction);

            Ln.i("Broker mirror active: task=" + task.getTaskId()
                    + " sourceDisplay=" + task.getDisplayId()
                    + " compositorDisplay=" + virtualDisplay.getDisplay().getDisplayId()
                    + " video=" + videoSize);
        } catch (Throwable throwable) {
            stop();
            Throwable cause = throwable.getCause() != null
                    ? throwable.getCause() : throwable;
            throw new IOException(
                    "Could not mirror task " + task.getTaskId() + ": "
                            + cause.getMessage(),
                    cause);
        }
    }

    @Override
    public void stop() {
        removeSurface(container != null ? container : mirror);
        transaction = null;
        mirror = null;
        container = null;
        if (virtualDisplay != null) {
            try {
                virtualDisplay.release();
            } catch (Throwable throwable) {
                Ln.w("Could not release broker compositor display");
            }
            virtualDisplay = null;
        }
    }

    @Override
    public void release() {
        stop();
        task.removeCapture(this);
    }

    @Override
    public Size getSize() {
        return videoSize;
    }

    @Override
    public boolean isClosed() {
        return closed || !task.isAlive();
    }

    @Override
    protected boolean applyNewVideoConstraints(VideoConstraints videoConstraints) {
        constraints = videoConstraints;
        return true;
    }

    Rect getSourceBounds() {
        return new Rect(sourceBounds);
    }

    void onTaskInfoChanged() {
        CaptureControl control = getCaptureControl();
        if (control != null) {
            control.reset(CaptureControl.RESET_REASON_DISPLAY_PROPERTIES_CHANGED);
        }
    }

    void onTaskVanished() {
        closed = true;
        CaptureControl control = getCaptureControl();
        if (control != null) {
            control.reset(CaptureControl.RESET_REASON_TERMINATED);
        }
    }

    private void removeSurface(Object surface) {
        if (transaction == null || surface == null) {
            return;
        }
        try {
            Class<?> surfaceControlClass = Class.forName("android.view.SurfaceControl");
            transaction.getClass().getMethod(
                    "remove",
                    surfaceControlClass).invoke(transaction, surface);
            transaction.getClass().getMethod("apply").invoke(transaction);
        } catch (Throwable throwable) {
            Ln.w("Could not remove broker mirror hierarchy cleanly");
        }
    }
}
