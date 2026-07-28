package com.genymobile.scrcpy.compositor;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;

final class CompositorBrokerProtocol {

    static final String SOCKET_NAME = "rewritedex_compositor_v1";
    static final int MAGIC = 0x52574442; // "RWDB"
    static final int VERSION = 1;

    static final int COMMAND_STREAM = 1;
    static final int COMMAND_PING = 2;
    static final int COMMAND_STOP = 3;

    static final int STATUS_OK = 0;
    static final int STATUS_BAD_REQUEST = 1;
    static final int STATUS_TASK_NOT_FOUND = 2;
    static final int STATUS_CAPTURE_FAILED = 3;

    private CompositorBrokerProtocol() {
        // no instances
    }

    static void writePrefix(DataOutputStream output, int command) throws IOException {
        output.writeInt(MAGIC);
        output.writeInt(VERSION);
        output.writeInt(command);
    }

    static int readAndValidateCommand(DataInputStream input) throws IOException {
        int magic = input.readInt();
        int version = input.readInt();
        int command = input.readInt();
        if (magic != MAGIC) {
            throw new IOException("Invalid broker magic: 0x" + Integer.toHexString(magic));
        }
        if (version != VERSION) {
            throw new IOException("Unsupported broker protocol version: " + version);
        }
        return command;
    }

    static void writeStatus(DataOutputStream output, int status, String message)
            throws IOException {
        output.writeInt(MAGIC);
        output.writeInt(VERSION);
        output.writeInt(status);
        output.writeUTF(message == null ? "" : message);
        output.flush();
    }

    static String readStatus(DataInputStream input) throws IOException {
        int magic = input.readInt();
        int version = input.readInt();
        int status = input.readInt();
        String message = input.readUTF();
        if (magic != MAGIC) {
            throw new IOException("Invalid broker response magic");
        }
        if (version != VERSION) {
            throw new IOException("Broker version changed while connecting");
        }
        if (status != STATUS_OK) {
            throw new IOException(
                    message.isEmpty() ? "Broker request failed with status " + status : message);
        }
        return message;
    }
}
