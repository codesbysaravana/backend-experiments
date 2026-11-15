
import com.sun.net.httpserver.HttpServer;

import java.net.InetSocketAddress;
import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.Executors;

public class ServerJ {
    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(8083), 0);

        server.setExecutor(Executors.newCachedThreadPool());

        server.createContext("/", exchange -> {
            try {
                Thread.sleep(100);

                String response = "Java Server";

                exchange.sendResponseHeaders(200, response.getBytes().length);

                OutputStream os = exchange.getResponseBody();
                os.write(response.getBytes());
                os.close();

            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });

        server.start();
        System.out.println("Platform Thread Server started");
    }
}
