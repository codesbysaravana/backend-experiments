package com.agent.app;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

public class Client {

    public static void main(String[] args) throws Exception {
        ensureServerRunning();

        System.out.println("==================================================");
        System.out.println(" TEST 1: socket.setTcpNoDelay(false) [Nagle ON]");
        System.out.println("==================================================");
        double avgWithNagle = runTest(false, 20);

        Thread.sleep(500);

        System.out.println("\n==================================================");
        System.out.println(" TEST 2: socket.setTcpNoDelay(true)  [Nagle OFF]");
        System.out.println("==================================================");
        double avgNoDelay = runTest(true, 20);

        System.out.println("\n==================================================");
        System.out.println("               BENCHMARK SUMMARY                  ");
        System.out.println("==================================================");
        System.out.printf(" Nagle ON  (setTcpNoDelay(false)): Average %.3f ms%n", avgWithNagle);
        System.out.printf(" Nagle OFF (setTcpNoDelay(true)) : Average %.3f ms%n", avgNoDelay);
        System.out.printf(" Difference                      : %.3f ms%n", (avgWithNagle - avgNoDelay));
        System.out.println("==================================================");

        System.exit(0);
    }

    private static double runTest(boolean tcpNoDelay, int iterations) throws Exception {
        double totalMs = 0;

        for (int i = 1; i <= iterations; i++) {
            Socket socket = new Socket("localhost", 8083);
            socket.setTcpNoDelay(tcpNoDelay);

            OutputStream out = socket.getOutputStream();
            InputStream in = socket.getInputStream();

            // 1. Record System.nanoTime() right before first write
            long start = System.nanoTime();

            // Two back-to-back writes (0 ms pause)
            out.write("HELLO".getBytes());
            out.write("WORLD".getBytes());
            out.flush();

            // Read "OK" reply
            byte[] response = new byte[16];
            int bytesRead = in.read(response);

            // 2. Record System.nanoTime() when OK comes back
            long end = System.nanoTime();

            double elapsedMs = (end - start) / 1_000_000.0;
            totalMs += elapsedMs;

            System.out.printf("Run #%02d: %.3f ms (Server replied: %s)%n",
                    i, elapsedMs, new String(response, 0, bytesRead).trim());

            socket.close();

            // Small gap between runs
            Thread.sleep(30);
        }

        double avg = totalMs / iterations;
        System.out.printf(">>> Average for %s: %.3f ms%n",
                (tcpNoDelay ? "Nagle OFF (NoDelay=true)" : "Nagle ON (NoDelay=false)"), avg);
        return avg;
    }

    private static void ensureServerRunning() {
        boolean portFree = false;
        try (ServerSocket ss = new ServerSocket(8083, 1, InetAddress.getByName("localhost"))) {
            portFree = true;
        } catch (IOException e) {
            portFree = false;
        }

        if (portFree) {
            System.out.println("Starting App server in background on port 8083...");
            Thread serverThread = new Thread(() -> {
                try {
                    App.main(new String[0]);
                } catch (Exception ex) {
                    ex.printStackTrace();
                }
            });
            serverThread.setDaemon(true);
            serverThread.start();
            try {
                Thread.sleep(400); // Give server a moment to bind
            } catch (InterruptedException ignored) {}
        } else {
            System.out.println("App server already running on port 8083.");
        }
    }
}