package com.genymobile.scrcpy.compositor;

import android.graphics.Rect;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.SystemClock;

import com.genymobile.scrcpy.AsyncProcessor;
import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.control.Controller;
import com.genymobile.scrcpy.util.IO;
import com.genymobile.scrcpy.util.Ln;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Relays one broker-owned encoded stream into a normal scrcpy video socket.
 */
public final class TaskBrokerRelay implements AsyncProcessor {

    private static final int CONNECT_ATTEMPTS = 60;
    private static final int CONNECT_DELAY_MS = 100;
    private static final String SERVER_JAR = "/data/local/tmp/scrcpy-server.jar";
    private static final String BROKER_CLASS =
            "com.genymobile.scrcpy.compositor.CompositorBroker";
    private static final String BROKER_LOG =
            "/data/local/tmp/rewritedex-compositor.log";

    private final FileDescriptor destination;
    private final Controller controller;
    private final Options options;
    private final AtomicBoolean stopped = new AtomicBoolean();

    private Thread thread;
    private LocalSocket brokerSocket;

    public TaskBrokerRelay(
            FileDescriptor destination,
            Controller controller,
            Options options) {
        this.destination = destination;
        this.controller = controller;
        this.options = options;
    }

    @Override
    public void start(TerminationListener listener) {
        thread = new Thread(() -> {
            boolean fatal = true;
            try {
                relay();
                fatal = false;
            } catch (IOException exception) {
                if (!stopped.get() && !IO.isBrokenPipe(exception)) {
                    Ln.e("Task compositor broker relay failed", exception);
                }
            } finally {
                listener.onTerminated(fatal && !stopped.get());
            }
        }, "task-broker-relay");
        thread.start();
    }

    @Override
    public void stop() {
        stopped.set(true);
        LocalSocket socket = brokerSocket;
        if (socket != null) {
            try {
                socket.shutdownInput();
                socket.shutdownOutput();
            } catch (IOException ignored) {
                // the broker may already have closed the task stream
            }
            try {
                socket.close();
            } catch (IOException ignored) {
                // already closed
            }
        }
    }

    @Override
    public void join() throws InterruptedException {
        if (thread != null) {
            thread.join();
        }
    }

    private void relay() throws IOException {
        brokerSocket = connectOrStartBroker();
        DataOutputStream output =
                new DataOutputStream(brokerSocket.getOutputStream());
        InputStream rawInput = brokerSocket.getInputStream();
        DataInputStream input = new DataInputStream(rawInput);

        CompositorBrokerProtocol.writePrefix(
                output,
                CompositorBrokerProtocol.COMMAND_STREAM);
        output.writeInt(options.getTaskId());
        output.writeInt(options.getMaxSize());
        output.writeInt(options.getVideoBitRate());
        output.writeInt(Math.round(options.getMaxFps() * 1000f));
        output.writeInt(options.getMinSizeAlignment());
        output.writeBoolean(options.getSendStreamMeta());
        output.writeBoolean(options.getSendFrameMeta());
        output.flush();

        CompositorBrokerProtocol.readStatus(input);
        int taskId = input.readInt();
        int displayId = input.readInt();
        Rect bounds = new Rect(
                input.readInt(),
                input.readInt(),
                input.readInt(),
                input.readInt());
        if (controller != null) {
            controller.setTaskInputBounds(displayId, bounds);
        }
        Ln.i("Connected to persistent task compositor: task=" + taskId
                + " display=" + displayId
                + " bounds=" + bounds.flattenToString());

        byte[] buffer = new byte[64 * 1024];
        while (!stopped.get()) {
            int count = rawInput.read(buffer);
            if (count == -1) {
                break;
            }
            IO.writeFully(destination, buffer, 0, count);
        }
    }

    private LocalSocket connectOrStartBroker() throws IOException {
        LocalSocket socket = tryConnect();
        if (socket != null) {
            return socket;
        }

        startBroker();
        IOException lastError = null;
        for (int attempt = 0; attempt < CONNECT_ATTEMPTS; ++attempt) {
            if (stopped.get()) {
                throw new IOException("Task compositor relay stopped");
            }
            SystemClock.sleep(CONNECT_DELAY_MS);
            try {
                socket = tryConnect();
                if (socket != null) {
                    return socket;
                }
            } catch (IOException exception) {
                lastError = exception;
            }
        }
        throw new IOException(
                "Persistent rooted compositor did not start",
                lastError);
    }

    private static LocalSocket tryConnect() throws IOException {
        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(
                    CompositorBrokerProtocol.SOCKET_NAME));
            return socket;
        } catch (IOException exception) {
            socket.close();
            return null;
        }
    }

    private static void startBroker() throws IOException {
        String command = "CLASSPATH=" + SERVER_JAR
                + " app_process / " + BROKER_CLASS
                + " >" + BROKER_LOG + " 2>&1 &";
        new ProcessBuilder("su", "-c", command).start();
        Ln.i("Starting persistent rooted RewriteDEX compositor broker");
    }
}
