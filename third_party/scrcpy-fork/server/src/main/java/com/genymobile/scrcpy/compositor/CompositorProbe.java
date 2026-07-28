package com.genymobile.scrcpy.compositor;

import android.os.Build;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;

/**
 * Runtime probe for RewriteDEX's privileged per-task compositor.
 *
 * This class is deliberately isolated from the normal scrcpy entry point. It is
 * invoked with app_process so we can validate the exact Android framework build
 * before enabling task-surface capture in the working desktop transport.
 */
public final class CompositorProbe {

    private CompositorProbe() {
        // no instances
    }

    private static void line(String key, Object value) {
        System.out.println("RWD_COMPOSITOR " + key + "=" + String.valueOf(value));
    }

    private static void describeClass(String name) {
        try {
            Class<?> clazz = Class.forName(name);
            line("class." + name, "present");
            for (Class<?> nested : clazz.getDeclaredClasses()) {
                line("nested." + name, nested.getName());
            }
            for (Constructor<?> constructor : clazz.getDeclaredConstructors()) {
                line("constructor." + name, constructor.toGenericString());
            }
            for (Method method : clazz.getDeclaredMethods()) {
                String methodName = method.getName();
                if (name.startsWith("android.view.SurfaceControl$")
                        || name.contains("ContentRecording")
                        || name.contains("IWindowManager")
                        || name.contains("WindowManagerGlobal")
                        || name.contains("VirtualDisplayConfig")
                        || name.contains("IMediaProjection")
                        || name.contains("DisplayManagerGlobal")
                        || name.contains("ActivityTaskManager")
                        || methodName.contains("register")
                        || methodName.contains("capture")
                        || methodName.contains("ContentRecording")
                        || methodName.contains("contentRecording")
                        || methodName.contains("Layer")
                        || methodName.contains("Surface")
                        || methodName.contains("Task")) {
                    line("method." + name + "." + methodName, method.toGenericString());
                }
            }
        } catch (Throwable throwable) {
            line("class." + name, "missing:" + throwable);
        }
    }

    private static Object createTaskOrganizer(Class<?> organizerClass) throws Exception {
        for (Constructor<?> constructor : organizerClass.getDeclaredConstructors()) {
            if (constructor.getParameterTypes().length == 0) {
                constructor.setAccessible(true);
                return constructor.newInstance();
            }
        }
        throw new NoSuchMethodException("TaskOrganizer has no zero-argument constructor");
    }

    private static Object readMember(Object instance, String methodName, String fieldName) {
        if (instance == null) {
            return null;
        }
        try {
            Method method = instance.getClass().getMethod(methodName);
            method.setAccessible(true);
            return method.invoke(instance);
        } catch (Throwable ignored) {
            try {
                Field field = instance.getClass().getField(fieldName);
                field.setAccessible(true);
                return field.get(instance);
            } catch (Throwable second) {
                return null;
            }
        }
    }

    private static void probeTaskOrganizer() {
        Object organizer = null;
        try {
            Class<?> organizerClass = Class.forName("android.window.TaskOrganizer");
            organizer = createTaskOrganizer(organizerClass);
            Method register = organizerClass.getMethod("registerOrganizer");
            @SuppressWarnings("unchecked")
            List<Object> appeared = (List<Object>) register.invoke(organizer);
            line("taskOrganizer.registered", true);
            line("taskOrganizer.initialTaskCount", appeared == null ? 0 : appeared.size());
            if (appeared != null) {
                for (Object item : appeared) {
                    Object taskInfo = readMember(item, "getTaskInfo", "mTaskInfo");
                    Object leash = readMember(item, "getLeash", "mLeash");
                    Object taskId = readMember(taskInfo, "getTaskId", "taskId");
                    Object displayId = readMember(taskInfo, "getDisplayId", "displayId");
                    Object topActivity = readMember(taskInfo, "getTopActivity", "topActivity");
                    Object valid = readMember(leash, "isValid", "mNativeObject");
                    line(
                            "task",
                            "id:" + taskId
                                    + ",display:" + displayId
                                    + ",top:" + topActivity
                                    + ",leash:" + (leash == null ? "null" : leash.getClass().getName())
                                    + ",valid:" + valid);
                }
            }
        } catch (Throwable throwable) {
            Throwable cause = throwable.getCause() != null ? throwable.getCause() : throwable;
            line("taskOrganizer.registered", false);
            line("taskOrganizer.error", cause.getClass().getName() + ":" + cause.getMessage());
        } finally {
            if (organizer != null) {
                try {
                    Method unregister = organizer.getClass().getMethod("unregisterOrganizer");
                    unregister.invoke(organizer);
                    line("taskOrganizer.unregistered", true);
                } catch (Throwable throwable) {
                    line("taskOrganizer.unregistered", false);
                }
            }
        }
    }

    public static void main(String[] args) {
        line("probeVersion", 1);
        line("sdk", Build.VERSION.SDK_INT);
        line("release", Build.VERSION.RELEASE);
        line("uid", android.os.Process.myUid());
        line("pid", android.os.Process.myPid());
        line("root", android.os.Process.myUid() == 0);

        describeClass("android.window.TaskOrganizer");
        describeClass("android.window.TaskAppearedInfo");
        describeClass("android.window.ScreenCapture");
        describeClass("android.window.ScreenCapture$ScreenCaptureParams");
        describeClass("android.window.ScreenCapture$ScreenCaptureParams$Builder");
        describeClass("android.window.ScreenCapture$ScreenCaptureResult");
        describeClass("android.window.ScreenCapture$LayerCaptureArgs");
        describeClass("android.window.ScreenCapture$LayerCaptureArgs$Builder");
        describeClass("android.view.SurfaceControl");
        describeClass("android.view.SurfaceControl$LayerCaptureArgs");
        describeClass("android.view.SurfaceControl$LayerCaptureArgs$Builder");
        describeClass("android.view.SurfaceControl$Builder");
        describeClass("android.view.SurfaceControl$Transaction");
        describeClass("android.view.ContentRecordingSession");
        describeClass("android.view.ContentRecordingSession$Builder");
        describeClass("android.hardware.display.VirtualDisplayConfig");
        describeClass("android.hardware.display.VirtualDisplayConfig$Builder");
        describeClass("android.hardware.display.DisplayManagerGlobal");
        describeClass("android.media.projection.IMediaProjectionManager");
        describeClass("android.media.projection.IMediaProjectionManager$Stub$Proxy");
        describeClass("android.media.projection.IMediaProjection");
        describeClass("android.media.projection.IMediaProjection$Stub$Proxy");
        describeClass("android.app.ActivityOptions$LaunchCookie");
        describeClass("android.media.projection.MediaProjection");
        describeClass("android.app.ActivityTaskManager");
        describeClass("android.app.IActivityTaskManager");
        describeClass("android.app.IActivityTaskManager$Stub$Proxy");
        describeClass("android.view.IWindowManager");
        describeClass("android.view.IWindowManager$Stub$Proxy");
        describeClass("android.view.WindowManagerGlobal");
        probeTaskOrganizer();
        line("complete", true);
    }
}
