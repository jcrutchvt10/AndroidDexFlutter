package com.genymobile.scrcpy.compositor;

import android.graphics.Rect;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.view.Surface;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;

/**
 * Sends one WindowManager task recording session into a MediaCodec surface.
 *
 * This validates the same zero-copy producer/consumer pairing used by the
 * eventual USB compositor stream, without involving the existing display
 * mirroring transport.
 */
public final class TaskRecordingEncoderProbe {

    private static final String MIME_TYPE = "video/avc";
    private static final long DEFAULT_DURATION_MS = 3_000;

    private TaskRecordingEncoderProbe() {
        // no instances
    }

    private static void result(String key, Object value) {
        System.out.println("RWD_TASK_ENCODER " + key + "=" + String.valueOf(value));
    }

    private static void writeBuffer(
            MediaCodec codec,
            int bufferId,
            MediaCodec.BufferInfo info,
            FileOutputStream output) throws Exception {
        ByteBuffer buffer = codec.getOutputBuffer(bufferId);
        if (buffer == null || info.size <= 0) {
            return;
        }
        buffer.position(info.offset);
        buffer.limit(info.offset + info.size);
        byte[] bytes = new byte[info.size];
        buffer.get(bytes);
        output.write(bytes);
    }

    public static void main(String[] args) {
        if (android.os.Looper.myLooper() == null) {
            android.os.Looper.prepare();
        }
        if (args.length < 2) {
            result("usage", "TaskRecordingEncoderProbe <taskId> <output.h264> [durationMs]");
            System.exit(2);
        }

        int requestedTaskId = Integer.parseInt(args[0]);
        File destination = new File(args[1]);
        long durationMs = args.length >= 3 ? Long.parseLong(args[2]) : DEFAULT_DURATION_MS;
        Object projectionManager = null;
        Object mediaProjection = null;
        VirtualDisplay virtualDisplay = null;
        MediaCodec codec = null;
        Surface encoderSurface = null;
        boolean codecStarted = false;
        try {
            Object taskInfo = TaskRecordingSnapshot.findTaskInfo(
                    TaskRecordingSnapshot.listTasks(),
                    requestedTaskId);
            if (taskInfo == null) {
                throw new IllegalArgumentException(
                        "Task " + requestedTaskId + " was not returned by ActivityTaskManager");
            }
            Rect bounds = TaskRecordingSnapshot.taskBounds(taskInfo);
            int sourceWidth = bounds.width();
            int sourceHeight = bounds.height();
            int width = (sourceWidth + 15) & ~15;
            int height = (sourceHeight + 15) & ~15;
            result("taskId", requestedTaskId);
            result("bounds", bounds.flattenToString());
            result("sourceSize", sourceWidth + "x" + sourceHeight);
            result("encoderSize", width + "x" + height);
            result("uid", android.os.Process.myUid());

            projectionManager = TaskRecordingSnapshot.mediaProjectionManager();
            Object activeProjection = TaskRecordingSnapshot.activeProjectionInfo(projectionManager);
            if (activeProjection != null) {
                throw new IllegalStateException(
                        "An active MediaProjection already exists; refusing to replace it: " + activeProjection);
            }
            mediaProjection = TaskRecordingSnapshot.createMediaProjection(
                    projectionManager,
                    taskInfo,
                    requestedTaskId);

            MediaFormat format = MediaFormat.createVideoFormat(MIME_TYPE, width, height);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 4_000_000);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000);
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);
            codec = MediaCodec.createEncoderByType(MIME_TYPE);
            result("encoder", codec.getName());
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            encoderSurface = codec.createInputSurface();
            codec.start();
            codecStarted = true;

            virtualDisplay = TaskRecordingSnapshot.createRecordingDisplay(
                    "RewriteDEX-task-encoder-" + requestedTaskId,
                    width,
                    height,
                    encoderSurface,
                    mediaProjection);
            if (virtualDisplay == null || virtualDisplay.getDisplay() == null) {
                throw new IllegalStateException("WindowManager recording display creation failed");
            }
            result("compositorDisplayId", virtualDisplay.getDisplay().getDisplayId());

            File parent = destination.getParentFile();
            if (parent != null) {
                parent.mkdirs();
            }
            int buffers = 0;
            int frames = 0;
            long bytes = 0;
            long deadline = android.os.SystemClock.uptimeMillis() + durationMs;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            try (FileOutputStream output = new FileOutputStream(destination)) {
                while (android.os.SystemClock.uptimeMillis() < deadline) {
                    int bufferId = codec.dequeueOutputBuffer(info, 100_000);
                    if (bufferId >= 0) {
                        try {
                            if (info.size > 0) {
                                writeBuffer(codec, bufferId, info, output);
                                ++buffers;
                                bytes += info.size;
                                if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                                    ++frames;
                                }
                            }
                        } finally {
                            codec.releaseOutputBuffer(bufferId, false);
                        }
                    }
                }
            }
            result("buffers", buffers);
            result("frames", frames);
            result("bytes", bytes);
            result("output", destination.getAbsolutePath());
            if (frames == 0 || bytes == 0) {
                throw new IllegalStateException("MediaCodec received no task frames");
            }
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
                } catch (Throwable ignored) {
                    // process teardown stops the projection
                }
            }
            if (virtualDisplay != null) {
                try {
                    virtualDisplay.release();
                } catch (Throwable ignored) {
                    // process teardown releases it
                }
            }
            if (codec != null) {
                if (codecStarted) {
                    try {
                        codec.stop();
                    } catch (Throwable ignored) {
                        // encoder may already be stopped
                    }
                }
                codec.release();
            }
            if (encoderSurface != null) {
                encoderSurface.release();
            }
        }
    }
}
