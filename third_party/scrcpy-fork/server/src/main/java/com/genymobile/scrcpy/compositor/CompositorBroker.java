package com.genymobile.scrcpy.compositor;

import android.graphics.Rect;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Process;

import com.genymobile.scrcpy.BuildConfig;
import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.video.SurfaceEncoder;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Long-lived rooted compositor for concurrent RewriteDEX task surfaces.
 *
 * One process owns TaskOrganizer for the whole RewriteDEX session. Every
 * client receives a dedicated SurfaceControl mirror, VirtualDisplay and
 * MediaCodec encoder while all task leashes remain owned by this process.
 */
public final class CompositorBroker {

    private final PersistentTaskOrganizer organizer = new PersistentTaskOrganizer();
    private final AtomicBoolean stopping = new AtomicBoolean();
    private final AtomicBoolean cleanedUp = new AtomicBoolean();
    private final CopyOnWriteArrayList<LocalSocket> clients = new CopyOnWriteArrayList<>();

    private LocalServerSocket serverSocket;

    private CompositorBroker() {
        // use main()
    }

    public static void main(String[] args) {
        if (args.length > 0) {
            int command = "stop".equals(args[0])
                    ? CompositorBrokerProtocol.COMMAND_STOP
                    : CompositorBrokerProtocol.COMMAND_PING;
            try {
                sendControlCommand(command);
            } catch (Throwable throwable) {
                System.err.println("RWD_BROKER client_error=" + throwable.getMessage());
                System.exit(1);
            }
            return;
        }

        if (Process.myUid() != 0) {
            System.err.println("RWD_BROKER error=must_run_as_root uid=" + Process.myUid());
            System.exit(2);
        }

        CompositorBroker broker = new CompositorBroker();
        try {
            broker.run();
        } catch (Throwable throwable) {
            Throwable cause = throwable.getCause() != null
                    ? throwable.getCause() : throwable;
            System.err.println("RWD_BROKER fatal="
                    + cause.getClass().getName() + ":" + cause.getMessage());
            cause.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private void run() throws Exception {
        organizer.registerOnce();
        try {
            serverSocket = new LocalServerSocket(CompositorBrokerProtocol.SOCKET_NAME);
            System.out.println("RWD_BROKER ready=true uid=" + Process.myUid()
                    + " tasks=" + organizer.getTaskCount());
            while (!stopping.get()) {
                LocalSocket client;
                try {
                    client = serverSocket.accept();
                } catch (IOException exception) {
                    if (stopping.get()) {
                        break;
                    }
                    throw exception;
                }
                clients.add(client);
                Thread session = new Thread(
                        () -> handleClient(client),
                        "rwd-compositor-client");
                session.start();
            }
        } finally {
            shutdown();
            System.out.println("RWD_BROKER stopped=true");
        }
    }

    private void handleClient(LocalSocket client) {
        try {
            DataInputStream input = new DataInputStream(client.getInputStream());
            DataOutputStream output = new DataOutputStream(client.getOutputStream());
            int command = CompositorBrokerProtocol.readAndValidateCommand(input);
            switch (command) {
                case CompositorBrokerProtocol.COMMAND_PING:
                    CompositorBrokerProtocol.writeStatus(
                            output,
                            CompositorBrokerProtocol.STATUS_OK,
                            "ready tasks=" + organizer.getTaskCount());
                    break;
                case CompositorBrokerProtocol.COMMAND_STOP:
                    CompositorBrokerProtocol.writeStatus(
                            output,
                            CompositorBrokerProtocol.STATUS_OK,
                            "stopping");
                    requestStop(client);
                    break;
                case CompositorBrokerProtocol.COMMAND_STREAM:
                    streamTask(input, output, client);
                    break;
                default:
                    CompositorBrokerProtocol.writeStatus(
                            output,
                            CompositorBrokerProtocol.STATUS_BAD_REQUEST,
                            "Unknown broker command: " + command);
                    break;
            }
        } catch (Throwable throwable) {
            if (!stopping.get()) {
                Throwable cause = throwable.getCause() != null
                        ? throwable.getCause() : throwable;
                Ln.e("RewriteDEX broker client failed: " + cause.getMessage());
            }
        } finally {
            clients.remove(client);
            try {
                client.close();
            } catch (IOException ignored) {
                // already closed
            }
        }
    }

    private void streamTask(
            DataInputStream input,
            DataOutputStream output,
            LocalSocket client) throws Exception {
        int taskId = input.readInt();
        int maxSize = input.readInt();
        int videoBitRate = input.readInt();
        int maxFpsMilli = input.readInt();
        int minSizeAlignment = input.readInt();
        boolean sendStreamMeta = input.readBoolean();
        boolean sendFrameMeta = input.readBoolean();

        PersistentTaskOrganizer.TaskRecord task = organizer.getTask(taskId);
        if (task == null) {
            CompositorBrokerProtocol.writeStatus(
                    output,
                    CompositorBrokerProtocol.STATUS_TASK_NOT_FOUND,
                    "Task " + taskId + " is not owned by the compositor broker");
            return;
        }
        Rect bounds = task.getBounds();
        if (bounds.isEmpty()) {
            CompositorBrokerProtocol.writeStatus(
                    output,
                    CompositorBrokerProtocol.STATUS_CAPTURE_FAILED,
                    "Task " + taskId + " has empty bounds");
            return;
        }

        CompositorBrokerProtocol.writeStatus(
                output,
                CompositorBrokerProtocol.STATUS_OK,
                "streaming");
        output.writeInt(taskId);
        output.writeInt(task.getDisplayId());
        output.writeInt(bounds.left);
        output.writeInt(bounds.top);
        output.writeInt(bounds.right);
        output.writeInt(bounds.bottom);
        output.flush();

        Options options = Options.parse(
                BuildConfig.VERSION_NAME,
                "video_codec=h264",
                "max_size=" + maxSize,
                "video_bit_rate=" + videoBitRate,
                "max_fps=" + ((float) maxFpsMilli / 1000f),
                "min_size_alignment=" + minSizeAlignment,
                "send_stream_meta=" + sendStreamMeta,
                "send_frame_meta=" + sendFrameMeta,
                "cleanup=false");
        BrokerMirrorCapture capture = new BrokerMirrorCapture(task);
        Streamer streamer = new Streamer(
                client.getFileDescriptor(),
                options.getVideoCodec(),
                options.getSendStreamMeta(),
                options.getSendFrameMeta());
        SurfaceEncoder encoder = new SurfaceEncoder(capture, streamer, options);
        CountDownLatch terminated = new CountDownLatch(1);
        encoder.start(fatalError -> terminated.countDown());
        try {
            terminated.await();
        } finally {
            encoder.stop();
            encoder.join();
        }
    }

    private void requestStop(LocalSocket controlClient) {
        if (!stopping.compareAndSet(false, true)) {
            return;
        }
        for (LocalSocket client : clients) {
            if (client == controlClient) {
                continue;
            }
            try {
                client.close();
            } catch (IOException ignored) {
                // already closed
            }
        }
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {
                // accept loop is already waking up
            }
        }
        Thread exitThread = new Thread(() -> {
            android.os.SystemClock.sleep(250);
            shutdown();
            System.exit(0);
        }, "rwd-compositor-stop");
        exitThread.start();
    }

    private void shutdown() {
        if (!cleanedUp.compareAndSet(false, true)) {
            return;
        }
        stopping.set(true);
        for (LocalSocket client : clients) {
            try {
                client.close();
            } catch (IOException ignored) {
                // already closed
            }
        }
        clients.clear();
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {
                // already closed
            }
        }
        organizer.releaseAll();
    }

    private static void sendControlCommand(int command) throws IOException {
        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(
                    CompositorBrokerProtocol.SOCKET_NAME));
            DataOutputStream output = new DataOutputStream(socket.getOutputStream());
            DataInputStream input = new DataInputStream(socket.getInputStream());
            CompositorBrokerProtocol.writePrefix(output, command);
            output.flush();
            String message = CompositorBrokerProtocol.readStatus(input);
            System.out.println("RWD_BROKER " + message);
        } finally {
            socket.close();
        }
    }
}
