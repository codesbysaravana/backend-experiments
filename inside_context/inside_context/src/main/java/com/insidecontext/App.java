package com.insidecontext;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.ArrayNode;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;        
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public class App {

    private static final ObjectMapper mapper = new ObjectMapper();

    private static final HttpClient client = HttpClient.newHttpClient();

    // Each conversation has its own message history.
    private static final Map<String, List<ObjectNode>> CONVERSATIONS = new ConcurrentHashMap<>();

    public static void main(String[] args) throws IOException {

        HttpServer server = HttpServer.create(new InetSocketAddress(8081), 0);

        server.createContext("/", exchange -> {
            sendResponse(
                exchange,
                200,
                "Hello from Server!",
                "text/plain"
            );
        });

                
        server.createContext("/openai", exchange -> {

            if (!exchange.getRequestMethod().equals("POST")) {
                sendResponse(exchange, 405,
                    "Only POST is supported", "text/plain");
                return;
            }

            String apiKey = System.getenv("OPENAI_API_KEY");

            if (apiKey == null || apiKey.isBlank()) {
                sendResponse(exchange, 500,
                    "Missing API key", "text/plain");
                return;
            }

            try {

                JsonNode incoming = mapper.readTree(exchange.getRequestBody());
                JsonNode promptNode = incoming.get("prompt");

                if (promptNode == null ||
                    !promptNode.isTextual() ||
                    promptNode.asText().isBlank()) {

                    sendResponse(exchange, 400,
                        "A valid prompt is required", "text/plain");
                    return;
                }

                String userPrompt = promptNode.asText();

                // Get or create conversation ID.
                JsonNode conversationNode = incoming.get("conversation_id");

                String conversationId =
                    conversationNode != null &&
                    conversationNode.isTextual() &&
                    !conversationNode.asText().isBlank()
                    ? conversationNode.asText()
                    : UUID.randomUUID().toString();

                // Get conversation history.
                List<ObjectNode> history = CONVERSATIONS.computeIfAbsent(
                    conversationId,
                    id -> new ArrayList<>()
                );

                synchronized (history) {

                    // Construct original payload.
                    ObjectNode payload = mapper.createObjectNode();
                    payload.put("model", "gpt-4o-mini");

                    ArrayNode messages = payload.putArray("messages");

                    // System message.
                    ObjectNode systemMessage = messages.addObject();
                    systemMessage.put("role", "system");
                    systemMessage.put(
                        "content",
                        "You are a helpful AI assistant."
                    );

                    // Add complete conversation history.
                    for (ObjectNode message : history) {
                        messages.add(message.deepCopy());
                    }

                    // Current user message.
                    ObjectNode userMessage = mapper.createObjectNode();
                    userMessage.put("role", "user");
                    userMessage.put("content", userPrompt);

                    messages.add(userMessage.deepCopy());

                    String jsonBody = mapper.writeValueAsString(payload);

                    // Build original request.
                    HttpRequest request = HttpRequest.newBuilder()
                        .uri(URI.create(
                            "https://api.openai.com/v1/chat/completions"
                        ))
                        .header("Content-Type", "application/json")
                        .header("Authorization", "Bearer " + apiKey)
                        .POST(HttpRequest.BodyPublishers.ofString(jsonBody))
                        .build();

                    // First API call.
                    HttpResponse<String> aiResponse = client.send(
                        request,
                        HttpResponse.BodyHandlers.ofString()
                    );

                    // Handle API errors.
                    if (aiResponse.statusCode() < 200 ||
                        aiResponse.statusCode() >= 300) {

                        JsonNode errorJson = mapper.readTree(aiResponse.body());

                        String errorCode = errorJson
                            .path("error")
                            .path("code")
                            .asText();

                        System.out.println("API Error Code: " + errorCode);

                        // Context window exceeded.
                        if ("context_length_exceeded".equals(errorCode)) {

                            System.out.println("Context limit exceeded!");
                            System.out.println("Rebuilding conversation history...");
                            
                            // Construct retry payload.
                            ObjectNode retryPayload = mapper.createObjectNode();
                            retryPayload.put("model", "gpt-4o-mini");

                            ArrayNode retryMessages =
                                retryPayload.putArray("messages");
                            
                            System.out.println("RETRY JSON BODY: " + retryPayload.toString());

                            // 1. Preserve system message.
                            ObjectNode retrySystem = retryMessages.addObject();
                            retrySystem.put("role", "system");
                            retrySystem.put(
                                "content",
                                "You are a helpful AI assistant."
                            );

                            // 2. Preserve FIRST 2 history messages.
                            int firstCount = Math.min(2, history.size());

                            for (int i = 0; i < firstCount; i++) {
                                retryMessages.add(history.get(i).deepCopy());
                            }

                            // 3. Preserve LAST 4 history messages.
                            // Avoid duplicating messages already included.
                            int lastStart = Math.max(
                                firstCount,
                                history.size() - 4
                            );

                            for (int i = lastStart; i < history.size(); i++) {
                                retryMessages.add(history.get(i).deepCopy());
                            }

                            // 4. Preserve current user prompt.
                            retryMessages.add(userMessage.deepCopy());

                            System.out.println(
                                "Original history messages: " + history.size()
                            );

                            System.out.println(
                                "Retry messages: " + retryMessages.size()
                            );

                            // Build retry request.
                            String retryBody =
                                mapper.writeValueAsString(retryPayload);

                            HttpRequest retryRequest = HttpRequest.newBuilder()
                                .uri(URI.create(
                                    "https://api.openai.com/v1/chat/completions"
                                ))
                                .header("Content-Type", "application/json")
                                .header("Authorization", "Bearer " + apiKey)
                                .POST(
                                    HttpRequest.BodyPublishers.ofString(retryBody)
                                )
                                .build();

                            // Retry exactly ONCE.
                            System.out.println("Retrying API request...");

                            aiResponse = client.send(
                                retryRequest,
                                HttpResponse.BodyHandlers.ofString()
                            );

                            System.out.println(
                                "Retry HTTP Status: " + aiResponse.statusCode()
                            );
                        }

                        // If the original error wasn't recoverable,
                        // or the retry also failed, return the API error.
                        if (aiResponse.statusCode() < 200 ||
                            aiResponse.statusCode() >= 300) {

                            sendResponse(
                                exchange,
                                aiResponse.statusCode(),
                                aiResponse.body(),
                                "application/json; charset=UTF-8"
                            );

                            return;
                        }
                    }

                    // Parse successful response.
                    JsonNode result = mapper.readTree(aiResponse.body());

                    JsonNode contentNode = result
                        .path("choices")
                        .path(0)
                        .path("message")
                        .path("content");

                    if (!contentNode.isTextual()) {
                        sendResponse(exchange, 502,
                            "Invalid AI response", "text/plain");
                        return;
                    }

                    String assistantReply = contentNode.asText();

                    // Store current user message.
                    history.add(userMessage.deepCopy());

                    // Store assistant response.
                    ObjectNode assistantMessage = mapper.createObjectNode();
                    assistantMessage.put("role", "assistant");
                    assistantMessage.put("content", assistantReply);

                    history.add(assistantMessage);

                    // Construct response.
                    ObjectNode response = mapper.createObjectNode();
                    response.put("conversation_id", conversationId);
                    response.put("answer", assistantReply);

                    // Token usage.
                    JsonNode usage = result.path("usage");

                    int promptTokens = usage.path("prompt_tokens").asInt();
                    int completionTokens = usage.path("completion_tokens").asInt();
                    int totalTokens = usage.path("total_tokens").asInt();

                    System.out.println("==============================");
                    System.out.println("Conversation ID: " + conversationId);
                    System.out.println("Prompt Tokens: " + promptTokens);
                    System.out.println("Completion Tokens: " + completionTokens);
                    System.out.println("Total Tokens: " + totalTokens);
                    System.out.println("Messages Stored: " + history.size());
                    System.out.println("==============================");

                    sendResponse(
                        exchange,
                        200,
                        mapper.writeValueAsString(response),
                        "application/json; charset=UTF-8"
                    );
                }

            } catch (InterruptedException e) {

                Thread.currentThread().interrupt();

                sendResponse(exchange, 503,
                    "Request interrupted", "text/plain");

            } catch (Exception e) {

                e.printStackTrace();

                sendResponse(exchange, 500,
                    "Internal server error", "text/plain");
            }
        });
  

        server.createContext("/stuff", exchange -> {
            try {
                JsonNode incoming = mapper.readTree(exchange.getRequestBody());

                JsonNode conversation_id = incoming.get("conversation_id");
                String conversationIdAsString = conversation_id.asText();

                JsonNode count = incoming.get("count");
                int countAsInt = count.asInt();

                if (countAsInt < 0 || countAsInt > 500) {
                    sendResponse(exchange, 400,
                        "Count must be between 0 and 500",
                        "text/plain");
                    return;
                }

                List<ObjectNode> convo = CONVERSATIONS.get(conversationIdAsString);

                if (convo == null) {
                    sendResponse(exchange, 404,
                        "Conversation not found",
                        "text/plain");
                    return;
                }

                synchronized (convo) {

                    long total = 0;

                    ObjectNode userMessage = mapper.createObjectNode();
                    userMessage.put("role", "user");
                    userMessage.put("content",
                        "In the ancient world of technology, enormous systems operated through complex networks of interconnected components, each responsible for maintaining a specific function within a larger environment. Every component communicated with other components through carefully defined interfaces, exchanging information, processing requests, and producing results. These interactions created a continuous flow of information that allowed the entire system to operate efficiently. Whenever a request entered the environment, multiple processes evaluated its contents, determined the appropriate execution path, and coordinated their activities to complete the requested operation. Some processes operated independently, while others depended on information generated by previously completed tasks. The system maintained internal records to ensure that important information remained accessible whenever subsequent operations required it. Reliability was achieved through careful coordination, consistent data structures, and predictable execution patterns. When unexpected conditions occurred, the system attempted to recover without compromising the integrity of previously stored information. Each operation contributed to the overall workload, and the accumulation of these operations gradually increased the amount of information maintained within the environment. As the workload expanded, resource consumption increased accordingly. Memory allocation, processing capacity, communication overhead, and storage requirements became increasingly important considerations. Engineers therefore introduced monitoring mechanisms to understand how individual components behaved under different operating conditions. These mechanisms collected measurements, evaluated performance indicators, and identified potential bottlenecks. The collected information helped engineers understand whether the system could continue operating efficiently as demand increased. In some situations, additional resources were required to maintain acceptable performance. In other situations, inefficient operations needed to be redesigned or optimized. The distinction between these situations was important because increasing resources without addressing inefficient behavior could introduce unnecessary operational costs. A well designed environment therefore required both effective resource management and careful application design. Every incoming request needed appropriate validation before processing began. Invalid information could otherwise introduce unexpected behavior or cause downstream components to fail. Structured logging provided visibility into the execution process and helped identify the origin of unexpected conditions. Monitoring tools also helped distinguish temporary performance fluctuations from persistent operational problems. Over time, engineers developed increasingly sophisticated methods for evaluating system behavior, testing different workloads, and measuring the impact of architectural decisions. These experiments provided valuable information about scalability, reliability, maintainability, and operational efficiency. The resulting observations influenced future implementation decisions and helped establish more predictable engineering practices. Although individual components performed relatively simple operations, their combined behavior produced a complex environment that required thoughtful coordination. Maintaining this environment demanded continuous observation, systematic testing, and careful consideration of potential failure conditions. Ultimately, the effectiveness of the entire architecture depended not only on the capabilities of its individual components but also on the quality of communication between them, the consistency of their shared information, and the ability of the system to respond appropriately when operating conditions changed");

                    ObjectNode assistantMessage = mapper.createObjectNode();
                    assistantMessage.put("role", "assistant");
                    assistantMessage.put("content",
                        "In the ancient world of technology, enormous systems operated through complex networks of interconnected components, each responsible for maintaining a specific function within a larger environment. Every component communicated with other components through carefully defined interfaces, exchanging information, processing requests, and producing results. These interactions created a continuous flow of information that allowed the entire system to operate efficiently. Whenever a request entered the environment, multiple processes evaluated its contents, determined the appropriate execution path, and coordinated their activities to complete the requested operation. Some processes operated independently, while others depended on information generated by previously completed tasks. The system maintained internal records to ensure that important information remained accessible whenever subsequent operations required it. Reliability was achieved through careful coordination, consistent data structures, and predictable execution patterns. When unexpected conditions occurred, the system attempted to recover without compromising the integrity of previously stored information. Each operation contributed to the overall workload, and the accumulation of these operations gradually increased the amount of information maintained within the environment. As the workload expanded, resource consumption increased accordingly. Memory allocation, processing capacity, communication overhead, and storage requirements became increasingly important considerations. Engineers therefore introduced monitoring mechanisms to understand how individual components behaved under different operating conditions. These mechanisms collected measurements, evaluated performance indicators, and identified potential bottlenecks. The collected information helped engineers understand whether the system could continue operating efficiently as demand increased. In some situations, additional resources were required to maintain acceptable performance. In other situations, inefficient operations needed to be redesigned or optimized. The distinction between these situations was important because increasing resources without addressing inefficient behavior could introduce unnecessary operational costs. A well designed environment therefore required both effective resource management and careful application design. Every incoming request needed appropriate validation before processing began. Invalid information could otherwise introduce unexpected behavior or cause downstream components to fail. Structured logging provided visibility into the execution process and helped identify the origin of unexpected conditions. Monitoring tools also helped distinguish temporary performance fluctuations from persistent operational problems. Over time, engineers developed increasingly sophisticated methods for evaluating system behavior, testing different workloads, and measuring the impact of architectural decisions. These experiments provided valuable information about scalability, reliability, maintainability, and operational efficiency. The resulting observations influenced future implementation decisions and helped establish more predictable engineering practices. Although individual components performed relatively simple operations, their combined behavior produced a complex environment that required thoughtful coordination. Maintaining this environment demanded continuous observation, systematic testing, and careful consideration of potential failure conditions. Ultimately, the effectiveness of the entire architecture depended not only on the capabilities of its individual components but also on the quality of communication between them, the consistency of their shared information, and the ability of the system to respond appropriately when operating conditions changed");

                    for (int i = 0; i < countAsInt; i++) {
                        convo.add(userMessage.deepCopy());
                        convo.add(assistantMessage.deepCopy());
                    }

                    for (ObjectNode curr : convo) {
                        long contentLength =
                            curr.path("content").asText().length();

                        total += contentLength;
                    }

                    long estimatedTokens = total / 4;

                    ObjectNode response = mapper.createObjectNode();

                    response.put("messages_stored", convo.size());
                    response.put("estimated_tokens", estimatedTokens);

                    sendResponse(
                        exchange,
                        200,
                        mapper.writeValueAsString(response),
                        "application/json; charset=UTF-8"
                    );
                }

            } catch (Exception e) {
                e.printStackTrace();

                sendResponse(exchange, 500,
                    "Internal server error",
                    "text/plain");
            }
        });

        server.start();

        System.out.println("Server running on port 8081");
    }

    private static void sendResponse(
        HttpExchange exchange,
        int status,
        String response,
        String contentType
    ) throws IOException {

        byte[] bytes = response.getBytes(StandardCharsets.UTF_8);

        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(status, bytes.length);

        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        } finally {
            exchange.close();
        }
    }
}




// JsonNode is read-only 
// ObjectNode is mutable