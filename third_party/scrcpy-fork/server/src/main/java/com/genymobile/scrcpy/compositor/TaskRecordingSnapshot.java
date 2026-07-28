package com.genymobile.scrcpy.compositor;

import android.content.Context;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.os.IBinder;
import android.view.Surface;

import com.genymobile.scrcpy.FakeContext;

import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.Executor;

/**
 * Proof-of-concept task compositor using WindowManager's task recording path.
 *
 * Unlike a cropped display recording, ContentRecordingSession asks
 * WindowManager to mirror one task hierarchy into a dedicated virtual display.
 * That display surface is the primitive which will later be connected to
 * MediaCodec and transported to an independent Windows window.
 */
public final class TaskRecordingSnapshot {

    private static final int FRAME_SETTLE_MS = 750;
    private static final int VIRTUAL_DISPLAY_FLAG_TRUSTED = 1 << 10;
    private static final int VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP = 1 << 11;
    private static final int VIRTUAL_DISPLAY_FLAG_ALWAYS_UNLOCKED = 1 << 12;

    private TaskRecordingSnapshot() {
        // no instances
    }

    private static void result(String key, Object value) {
        System.out.println("RWD_TASK_RECORDING " + key + "=" + String.valueOf(value));
    }

    static Object noArgInstance(String className) throws Exception {
        Class<?> clazz = Class.forName(className);
        Constructor<?> constructor = clazz.getDeclaredConstructor();
        constructor.setAccessible(true);
        return constructor.newInstance();
    }

    static Object member(Object instance, String methodName, String fieldName) throws Exception {
        try {
            Method method = instance.getClass().getMethod(methodName);
            method.setAccessible(true);
            return method.invoke(instance);
        } catch (NoSuchMethodException ignored) {
            Field field = instance.getClass().getField(fieldName);
            field.setAccessible(true);
            return field.get(instance);
        }
    }

    static int taskId(Object taskInfo) throws Exception {
        return ((Number) member(taskInfo, "getTaskId", "taskId")).intValue();
    }

    static Rect taskBounds(Object taskInfo) throws Exception {
        Object configuration = taskInfo.getClass().getField("configuration").get(taskInfo);
        Object windowConfiguration = configuration.getClass().getField("windowConfiguration").get(configuration);
        return new Rect((Rect) windowConfiguration.getClass().getMethod("getBounds").invoke(windowConfiguration));
    }

    static Object findTask(List<?> appeared, int requestedTaskId) throws Exception {
        for (Object item : appeared) {
            Object info = member(item, "getTaskInfo", "mTaskInfo");
            if (taskId(info) == requestedTaskId) {
                return item;
            }
        }
        return null;
    }

    static List<?> listTasks() throws Exception {
        Class<?> managerClass = Class.forName("android.app.ActivityTaskManager");
        Object service = managerClass.getMethod("getService").invoke(null);
        return (List<?>) service.getClass()
                .getMethod("getTasks", int.class, boolean.class, boolean.class, int.class)
                .invoke(service, 100, false, true, -1);
    }

    static Object findTaskInfo(List<?> tasks, int requestedTaskId) throws Exception {
        for (Object taskInfo : tasks) {
            if (taskId(taskInfo) == requestedTaskId) {
                return taskInfo;
            }
        }
        return null;
    }

    static VirtualDisplay createRecordingDisplay(
            String name,
            int width,
            int height,
            Surface surface,
            Object mediaProjection) throws Exception {
        int flags = android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
                | android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR
                | VIRTUAL_DISPLAY_FLAG_TRUSTED
                | VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP
                | VIRTUAL_DISPLAY_FLAG_ALWAYS_UNLOCKED;

        Class<?> configClass = Class.forName("android.hardware.display.VirtualDisplayConfig");
        Class<?> builderClass = Class.forName("android.hardware.display.VirtualDisplayConfig$Builder");
        Object builder = builderClass
                .getConstructor(String.class, int.class, int.class, int.class)
                .newInstance(name, width, height, 320);
        builderClass.getMethod("setFlags", int.class).invoke(builder, flags);
        builderClass.getMethod("setSurface", Surface.class).invoke(builder, surface);
        builderClass.getMethod("setWindowManagerMirroringEnabled", boolean.class).invoke(builder, true);
        Object config = builderClass.getMethod("build").invoke(builder);

        Class<?> globalClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Object global = globalClass.getMethod("getInstance").invoke(null);
        Class<?> mediaProjectionClass = Class.forName("android.media.projection.MediaProjection");
        Executor directExecutor = Runnable::run;
        return (VirtualDisplay) globalClass.getMethod(
                        "createVirtualDisplay",
                        Context.class,
                        mediaProjectionClass,
                        configClass,
                        VirtualDisplay.Callback.class,
                        Executor.class)
                .invoke(global, FakeContext.get(), mediaProjection, config, null, directExecutor);
    }

    static Object mediaProjectionManager() throws Exception {
        Class<?> serviceManagerClass = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) serviceManagerClass
                .getMethod("getService", String.class)
                .invoke(null, "media_projection");
        if (binder == null) {
            throw new IllegalStateException("media_projection service is unavailable");
        }
        Class<?> stubClass = Class.forName("android.media.projection.IMediaProjectionManager$Stub");
        return stubClass.getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    static Object activeProjectionInfo(Object manager) throws Exception {
        return manager.getClass().getMethod("getActiveProjectionInfo").invoke(manager);
    }

    static Object createMediaProjection(
            Object manager,
            Object taskInfo,
            int requestedTaskId) throws Exception {
        Object token = member(taskInfo, "getToken", "token");
        IBinder taskBinder = (IBinder) token.getClass().getMethod("asBinder").invoke(token);
        Class<?> projectionInterface = Class.forName("android.media.projection.IMediaProjection");
        Object projectionToken = manager.getClass()
                .getMethod("createProjection", int.class, String.class, int.class, boolean.class, int.class)
                .invoke(
                        manager,
                        android.os.Process.myUid(),
                        FakeContext.PACKAGE_NAME,
                        0, // MediaProjectionManager.TYPE_SCREEN_CAPTURE
                        false,
                        android.view.Display.DEFAULT_DISPLAY);

        Class<?> launchCookieClass = Class.forName("android.app.ActivityOptions$LaunchCookie");
        Constructor<?> cookieConstructor = launchCookieClass.getDeclaredConstructor(IBinder.class);
        cookieConstructor.setAccessible(true);
        Object launchCookie = cookieConstructor.newInstance(taskBinder);
        projectionToken.getClass()
                .getMethod("setLaunchCookie", launchCookieClass)
                .invoke(projectionToken, launchCookie);
        projectionToken.getClass()
                .getMethod("setTaskId", int.class)
                .invoke(projectionToken, requestedTaskId);

        Class<?> mediaProjectionClass = Class.forName("android.media.projection.MediaProjection");
        return mediaProjectionClass
                .getConstructor(Context.class, projectionInterface)
                .newInstance(FakeContext.get(), projectionToken);
    }

    public static void main(String[] args) {
        if (android.os.Looper.myLooper() == null) {
            android.os.Looper.prepare();
        }
        if (args.length < 2) {
            result("usage", "TaskRecordingSnapshot <taskId> <output.png>");
            System.exit(2);
        }

        int requestedTaskId = Integer.parseInt(args[0]);
        File destination = new File(args[1]);
        Object projectionManager = null;
        Object mediaProjection = null;
        VirtualDisplay virtualDisplay = null;
        ImageReader reader = null;
        try {
            Object taskInfo = findTaskInfo(listTasks(), requestedTaskId);
            if (taskInfo == null) {
                throw new IllegalArgumentException("Task " + requestedTaskId + " was not returned by ActivityTaskManager");
            }

            Rect bounds = taskBounds(taskInfo);
            int width = bounds.width();
            int height = bounds.height();
            if (width <= 0 || height <= 0) {
                throw new IllegalStateException("Task has invalid bounds " + bounds);
            }
            result("taskId", requestedTaskId);
            result("bounds", bounds.flattenToString());
            result("size", width + "x" + height);
            result("uid", android.os.Process.myUid());

            projectionManager = mediaProjectionManager();
            Object activeProjection = activeProjectionInfo(projectionManager);
            if (activeProjection != null) {
                throw new IllegalStateException(
                        "An active MediaProjection already exists; refusing to replace it: " + activeProjection);
            }
            mediaProjection = createMediaProjection(projectionManager, taskInfo, requestedTaskId);
            result("projectionStarted", true);

            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2);
            virtualDisplay = createRecordingDisplay(
                    "RewriteDEX-task-recording-" + requestedTaskId,
                    width,
                    height,
                    reader.getSurface(),
                    mediaProjection);
            if (virtualDisplay == null || virtualDisplay.getDisplay() == null) {
                throw new IllegalStateException("WindowManager recording display creation failed");
            }
            int displayId = virtualDisplay.getDisplay().getDisplayId();
            result("compositorDisplayId", displayId);
            result("sessionAccepted", true);

            Thread.sleep(FRAME_SETTLE_MS);
            try (Image frame = TaskSurfaceSnapshot.awaitImage(reader)) {
                if (frame == null) {
                    throw new IllegalStateException("Timed out waiting for the task recording surface");
                }
                TaskSurfaceSnapshot.writePng(frame, width, height, destination);
            }
            result("output", destination.getAbsolutePath());
            result("bytes", destination.length());
            result("success", true);
        } catch (Throwable throwable) {
            Throwable cause = throwable.getCause() != null ? throwable.getCause() : throwable;
            result("error", cause.getClass().getName() + ":" + cause.getMessage());
            result("success", false);
            cause.printStackTrace(System.err);
            System.exit(1);
        } finally {
            if (mediaProjection != null) {
                try {
                    mediaProjection.getClass().getMethod("stop").invoke(mediaProjection);
                    result("projectionStopped", true);
                } catch (Throwable throwable) {
                    result("projectionStopped", false);
                }
            }
            if (virtualDisplay != null) {
                try {
                    virtualDisplay.release();
                } catch (Throwable ignored) {
                    // process teardown releases it
                }
            }
            if (reader != null) {
                reader.close();
            }
        }
    }
}
