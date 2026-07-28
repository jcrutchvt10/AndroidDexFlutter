package com.genymobile.scrcpy.compositor;

import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.view.Surface;

import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Captures one TaskOrganizer leash through a dedicated SurfaceFlinger display.
 *
 * This is the first functional RewriteDEX per-task compositor primitive. It
 * produces a task-only PNG without cropping a full-display screenshot. The
 * same mirror/display chain will feed a MediaCodec input Surface for streaming.
 */
public final class TaskSurfaceSnapshot {

    private static final long IMAGE_TIMEOUT_MS = 4_000;

    private TaskSurfaceSnapshot() {
        // no instances
    }

    private static void result(String key, Object value) {
        System.out.println("RWD_TASK_SURFACE " + key + "=" + String.valueOf(value));
    }

    private static Object noArgInstance(String className) throws Exception {
        Class<?> clazz = Class.forName(className);
        Constructor<?> constructor = clazz.getDeclaredConstructor();
        constructor.setAccessible(true);
        return constructor.newInstance();
    }

    private static Object member(Object instance, String methodName, String fieldName) throws Exception {
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

    private static int taskId(Object taskInfo) throws Exception {
        Object value = member(taskInfo, "getTaskId", "taskId");
        return ((Number) value).intValue();
    }

    private static Rect taskBounds(Object taskInfo) throws Exception {
        Field configurationField = taskInfo.getClass().getField("configuration");
        Object configuration = configurationField.get(taskInfo);
        Field windowConfigurationField = configuration.getClass().getField("windowConfiguration");
        Object windowConfiguration = windowConfigurationField.get(configuration);
        Method getBounds = windowConfiguration.getClass().getMethod("getBounds");
        return new Rect((Rect) getBounds.invoke(windowConfiguration));
    }

    private static Object findTask(List<?> appeared, int requestedTaskId) throws Exception {
        for (Object item : appeared) {
            Object info = member(item, "getTaskInfo", "mTaskInfo");
            if (taskId(info) == requestedTaskId) {
                return item;
            }
        }
        return null;
    }

    static Image awaitImage(ImageReader reader) throws InterruptedException {
        long deadline = android.os.SystemClock.uptimeMillis() + IMAGE_TIMEOUT_MS;
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            Image image = reader.acquireLatestImage();
            if (image != null) {
                return image;
            }
            Thread.sleep(20);
        }
        return null;
    }

    static void writePng(Image image, int width, int height, File destination) throws Exception {
        Image.Plane plane = image.getPlanes()[0];
        ByteBuffer buffer = plane.getBuffer();
        int pixelStride = plane.getPixelStride();
        int rowStride = plane.getRowStride();
        int rowPadding = rowStride - pixelStride * width;
        int paddedWidth = width + rowPadding / pixelStride;
        Bitmap padded = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888);
        buffer.rewind();
        padded.copyPixelsFromBuffer(buffer);
        Bitmap cropped = Bitmap.createBitmap(padded, 0, 0, width, height);
        File parent = destination.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        try (FileOutputStream output = new FileOutputStream(destination)) {
            if (!cropped.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                throw new IllegalStateException("Bitmap PNG compression failed");
            }
        } finally {
            cropped.recycle();
            padded.recycle();
        }
    }

    static void captureDisplayToPng(int displayId, File destination) throws Exception {
        Class<?> builderClass = Class.forName("android.window.ScreenCapture$ScreenCaptureParams$Builder");
        Object builder = builderClass.getConstructor(int.class).newInstance(displayId);
        Object params = builderClass.getMethod("build").invoke(builder);
        Class<?> paramsClass = Class.forName("android.window.ScreenCapture$ScreenCaptureParams");
        Class<?> receiverClass = Class.forName("android.os.OutcomeReceiver");
        AtomicReference<Object> captureResult = new AtomicReference<>();
        AtomicReference<Throwable> captureError = new AtomicReference<>();
        CountDownLatch completed = new CountDownLatch(1);
        Object receiver = Proxy.newProxyInstance(
                receiverClass.getClassLoader(),
                new Class<?>[]{receiverClass},
                (proxy, method, args) -> {
                    if ("onResult".equals(method.getName())) {
                        captureResult.set(args[0]);
                        completed.countDown();
                    } else if ("onError".equals(method.getName())) {
                        captureError.set((Throwable) args[0]);
                        completed.countDown();
                    }
                    return null;
                });
        Executor directExecutor = Runnable::run;
        Class<?> screenCaptureClass = Class.forName("android.window.ScreenCapture");
        screenCaptureClass.getMethod("capture", paramsClass, Executor.class, receiverClass)
                .invoke(null, params, directExecutor, receiver);
        if (!completed.await(IMAGE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw new IllegalStateException("Timed out waiting for Android 17 ScreenCapture");
        }
        if (captureError.get() != null) {
            throw new IllegalStateException("ScreenCapture failed", captureError.get());
        }
        Object result = captureResult.get();
        if (result == null) {
            throw new IllegalStateException("ScreenCapture returned no result");
        }
        Object colorSpace = result.getClass().getMethod("getColorSpace").invoke(result);
        Object hardwareBuffer = result.getClass().getMethod("getHardwareBuffer").invoke(result);
        Class<?> hardwareBufferClass = Class.forName("android.hardware.HardwareBuffer");
        Bitmap hardwareBitmap = (Bitmap) Bitmap.class
                .getMethod("wrapHardwareBuffer", hardwareBufferClass, android.graphics.ColorSpace.class)
                .invoke(null, hardwareBuffer, colorSpace);
        if (hardwareBitmap == null) {
            throw new IllegalStateException("Could not wrap capture hardware buffer");
        }
        Bitmap softwareBitmap = hardwareBitmap.copy(Bitmap.Config.ARGB_8888, false);
        try (FileOutputStream output = new FileOutputStream(destination)) {
            if (!softwareBitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                throw new IllegalStateException("ScreenCapture PNG compression failed");
            }
        } finally {
            softwareBitmap.recycle();
            hardwareBitmap.recycle();
            hardwareBufferClass.getMethod("close").invoke(hardwareBuffer);
        }
    }

    private static void applyMirrorTransaction(
            Object transaction,
            Class<?> surfaceControlClass,
            Object container,
            Object mirror,
            int layerStack,
            int width,
            int height) throws Exception {
        Class<?> transactionClass = transaction.getClass();
        transactionClass.getMethod("setLayerStack", surfaceControlClass, int.class)
                .invoke(transaction, container, layerStack);
        transactionClass.getMethod("reparent", surfaceControlClass, surfaceControlClass)
                .invoke(transaction, mirror, container);
        transactionClass.getMethod("setPosition", surfaceControlClass, float.class, float.class)
                .invoke(transaction, mirror, 0f, 0f);
        transactionClass.getMethod("setCrop", surfaceControlClass, Rect.class)
                .invoke(transaction, mirror, new Rect(0, 0, width, height));
        transactionClass.getMethod("setLayer", surfaceControlClass, int.class)
                .invoke(transaction, mirror, 1);
        transactionClass.getMethod("show", surfaceControlClass).invoke(transaction, mirror);
        transactionClass.getMethod("show", surfaceControlClass).invoke(transaction, container);
        transactionClass.getMethod("apply").invoke(transaction);
    }

    private static void removeMirror(Object transaction, Class<?> surfaceControlClass, Object mirror) {
        if (transaction == null || mirror == null) {
            return;
        }
        try {
            transaction.getClass().getMethod("remove", surfaceControlClass).invoke(transaction, mirror);
            transaction.getClass().getMethod("apply").invoke(transaction);
        } catch (Throwable ignored) {
            // Process teardown also releases the temporary mirror.
        }
    }

    public static void main(String[] args) {
        if (android.os.Looper.myLooper() == null) {
            android.os.Looper.prepare();
        }
        if (args.length < 2) {
            result("usage", "TaskSurfaceSnapshot <taskId> <output.png>");
            System.exit(2);
        }

        int requestedTaskId = Integer.parseInt(args[0]);
        File destination = new File(args[1]);
        Object organizer = null;
        Object transaction = null;
        Object container = null;
        Object mirror = null;
        VirtualDisplay virtualDisplay = null;
        ImageReader reader = null;
        Image image = null;
        Class<?> surfaceControlClass = null;
        try {
            Class<?> organizerClass = Class.forName("android.window.TaskOrganizer");
            organizer = noArgInstance("android.window.TaskOrganizer");
            @SuppressWarnings("unchecked")
            List<Object> appeared = (List<Object>) organizerClass
                    .getMethod("registerOrganizer")
                    .invoke(organizer);
            Object item = findTask(appeared, requestedTaskId);
            if (item == null) {
                throw new IllegalArgumentException("Task " + requestedTaskId + " was not returned by TaskOrganizer");
            }

            Object taskInfo = member(item, "getTaskInfo", "mTaskInfo");
            Object leash = member(item, "getLeash", "mLeash");
            Rect bounds = taskBounds(taskInfo);
            int width = bounds.width();
            int height = bounds.height();
            if (width <= 0 || height <= 0) {
                throw new IllegalStateException("Task has invalid bounds " + bounds);
            }
            result("taskId", requestedTaskId);
            result("bounds", bounds.flattenToString());
            result("size", width + "x" + height);

            surfaceControlClass = Class.forName("android.view.SurfaceControl");
            mirror = surfaceControlClass.getMethod("mirrorSurface", surfaceControlClass).invoke(null, leash);
            Class<?> builderClass = Class.forName("android.view.SurfaceControl$Builder");
            Object builder = builderClass.getDeclaredConstructor().newInstance();
            builder = builderClass.getMethod("setName", String.class)
                    .invoke(builder, "RewriteDEX-task-container-" + requestedTaskId);
            builder = builderClass.getMethod("setContainerLayer").invoke(builder);
            container = builderClass.getMethod("build").invoke(builder);

            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2);
            Surface outputSurface = reader.getSurface();
            // Android 17 removed SurfaceControl.createDisplay(). A private
            // OWN_CONTENT_ONLY virtual display still gives us an isolated
            // layer stack backed directly by the ImageReader/MediaCodec Surface.
            int displayFlags = android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                    | android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
                    | android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY;
            virtualDisplay = ServiceManager.getDisplayManager().createNewVirtualDisplay(
                    "RewriteDEX-task-" + requestedTaskId,
                    width,
                    height,
                    320,
                    outputSurface,
                    displayFlags);
            int compositorDisplayId = virtualDisplay.getDisplay().getDisplayId();
            DisplayInfo compositorDisplay = ServiceManager.getDisplayManager().getDisplayInfo(compositorDisplayId);
            if (compositorDisplay == null) {
                throw new IllegalStateException("Could not resolve compositor virtual display");
            }
            int layerStack = compositorDisplay.getLayerStack();
            result("compositorDisplayId", compositorDisplayId);
            result("layerStack", layerStack);

            Class<?> transactionClass = Class.forName("android.view.SurfaceControl$Transaction");
            transaction = transactionClass.getDeclaredConstructor().newInstance();
            applyMirrorTransaction(transaction, surfaceControlClass, container, mirror, layerStack, width, height);

            // Android 17 exposes display readback through android.window.ScreenCapture.
            // Capture the isolated display after SurfaceFlinger has committed the
            // mirror tree; the ImageReader Surface keeps the virtual display alive.
            Thread.sleep(150);
            captureDisplayToPng(compositorDisplayId, destination);
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
            if (image != null) {
                image.close();
            }
            removeMirror(transaction, surfaceControlClass, container != null ? container : mirror);
            if (reader != null) {
                reader.close();
            }
            if (virtualDisplay != null) {
                try {
                    virtualDisplay.release();
                } catch (Throwable ignored) {
                    // process teardown releases it
                }
            }
            if (organizer != null) {
                try {
                    organizer.getClass().getMethod("unregisterOrganizer").invoke(organizer);
                } catch (Throwable ignored) {
                    // process teardown releases the organizer binder
                }
            }
        }
    }
}
