package com.genymobile.scrcpy.compositor;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;

/**
 * Minimal broker control entry point.
 *
 * Keeping this separate from {@link CompositorBroker} avoids loading or
 * verifying TaskOrganizer hidden-API types in short-lived shell clients.
 */
public final class CompositorBrokerControl {

    private CompositorBrokerControl() {
        // no instances
    }

    public static void main(String[] args) {
        int command = args.length > 0 && "stop".equals(args[0])
                ? CompositorBrokerProtocol.COMMAND_STOP
                : CompositorBrokerProtocol.COMMAND_PING;
        try {
            send(command);
        } catch (Throwable throwable) {
            System.err.println(
                    "RWD_BROKER client_error=" + throwable.getMessage());
            System.exit(1);
        }
    }

    private static void send(int command) throws IOException {
        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(
                    CompositorBrokerProtocol.SOCKET_NAME));
            DataOutputStream output =
                    new DataOutputStream(socket.getOutputStream());
            DataInputStream input =
                    new DataInputStream(socket.getInputStream());
            CompositorBrokerProtocol.writePrefix(output, command);
            output.flush();
            String message = CompositorBrokerProtocol.readStatus(input);
            System.out.println("RWD_BROKER " + message);
        } finally {
            socket.close();
        }
    }
}
