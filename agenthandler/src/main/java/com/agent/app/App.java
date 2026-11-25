package com.agent.app;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

public class App {

    public static void main(String[] args) throws IOException {
        ServerSocket server = new ServerSocket(8083, 50, InetAddress.getByName("localhost"));
        System.out.println("Server listening on port 8083 (Press Ctrl+C to stop)...");

        int connectionCount = 0;

        // Outer loop to accept multiple client connections
        while (true) {
            Socket client = server.accept();
            connectionCount++;
            System.out.println("\n--- Connection #" + connectionCount + " ---");

            InputStream input = client.getInputStream();
            OutputStream output = client.getOutputStream();

            byte[] buffer = new byte[10];
            int totalBytesRead = 0;

            while (totalBytesRead < 10) {
                int bytesRead = input.read(buffer, totalBytesRead, 10 - totalBytesRead);
                if (bytesRead == -1) {
                    System.out.println("Client closed stream early.");
                    break;
                }
                totalBytesRead += bytesRead;
                System.out.println("Read " + bytesRead + " bytes (total: " + totalBytesRead + "/10)");
            }

            System.out.println("Received: " + new String(buffer, 0, totalBytesRead));

            output.write("OK\n".getBytes());
            output.flush();

            client.close();
        }
    }
}