# Netty Scaling — 1M req/s HTTP Server

A bare-metal HTTP server built with Netty 4 and Java 21, designed to understand the reactor pattern from the socket level up and push toward 1M requests/second on AWS.

---

## The Problem

Frameworks like Spring Boot abstract away the networking layer entirely. This experiment strips all of that away to answer:

- How does the **reactor pattern** actually work at the TCP level?
- How do **boss groups** and **worker groups** map to CPU cores?
- What's the difference between TCP connections, application threads, and CPU workers?
- How far can a **single JVM** push req/s before you need horizontal scaling?

---

## What's Built

A Netty 4 HTTP/1.1 server with:

- **1 boss thread** — accepts incoming TCP connections
- **N worker threads** (default: CPU core count) — handle all I/O on accepted connections via NIO event loops
- **`HttpServerCodec`** — decodes raw bytes into `HttpRequest` objects
- **`HttpServerHandler`** — custom handler that serves responses and exposes a `/metrics` endpoint
- **Micrometer + Prometheus** — `http_requests_total` counter, scrapeable at `/metrics`
- **HTTP/1.1 keep-alive** — connection reuse under load

### Architecture

```
Client (wrk) ──TCP──▶ Boss Group (1 thread, accepts connections)
                            │
                     ┌──────┴──────┐
                     ▼             ▼
              Worker Thread   Worker Thread   ... (N = CPU cores)
                │                   │
          ┌─────┴─────┐       ┌────┴─────┐
          ▼           ▼       ▼          ▼
    HttpServerCodec  Handler  HttpServerCodec  Handler
    (decode bytes)   (respond) (decode bytes)  (respond)
```

### Channel Pipeline

Each new connection gets its own pipeline:

```java
ch.pipeline()
    .addLast(new HttpServerCodec())      // Stage 1: decode raw bytes → HttpRequest
    .addLast(new HttpServerHandler());   // Stage 2: handle request, write response
```

Designed to be extendable (auth, logging, routing stages can be added):

```java
// Future pipeline stages:
.addLast(new AuthHandler())      // JWT validation
.addLast(new LoggingHandler())   // Request logging
.addLast(new RouterHandler())    // HashMap-based URL routing
```

---

## AWS Benchmarking Setup

### Instances

| Purpose | Instance | vCPU | Count |
|---|---|---|---|
| Server (Netty app) | `c6i.4xlarge` | 16 | 2–3 |
| Load generator (wrk) | `c6i.2xlarge` | 8 | 1 |

### Infrastructure

- **Spot instances** for everything — benchmark, not production
- **NLB** (Network Load Balancer) — Layer 4, zero HTTP overhead
- **Cluster Placement Group** — instances physically co-located, minimal latency
- Same **VPC**, same **Availability Zone** — no cross-AZ latency, no extra charges

### Estimated Cost

~$5–8 for a full 4-hour benchmark session on spot pricing.

### Benchmarking Checklist

1. Set billing alarm at $20
2. Launch `c6i.4xlarge` Spot — server instance
3. Launch `c6i.2xlarge` Spot — load generator instance (separate)
4. SSH in, copy the fat JAR, run the server
5. Run `wrk` from the load generator
6. Watch Prometheus metrics live
7. Tune → benchmark → repeat
8. **Terminate both instances when done**

---

## How to Run

### Prerequisites

- Java 21
- Gradle (wrapper included)

### Run locally

```bash
cd nettyscaling
./gradlew run          # Starts server on port 8000
```

### Load test

```bash
# From a separate terminal, WSL, or another machine:
wrk -t4 -c100 -d10s http://localhost:8000
```

Parameters: `-t` threads, `-c` concurrent connections, `-d` duration.

### WSL note

WSL creates virtual network ports. To access localhost from WSL, find the host IP:

```bash
ip route show | grep default | awk '{print $3}'
```

Then use that IP instead of `localhost`.

### Build a fat JAR

```bash
./gradlew jar
# Output: app/build/libs/app.jar
java -jar app/build/libs/app.jar
```

### Prometheus

`prometheus.yml` is preconfigured to scrape:
- `:8000` — Netty server metrics (`/metrics` endpoint)
- `:9100` — Node exporter (system metrics)

---

## File Map

```
nettyscaling/
├── app/
│   ├── build.gradle                                   # Netty 4.1.119, Micrometer Prometheus, Java 21
│   └── src/main/java/org/example/
│       ├── App.java                                   # ServerBootstrap — boss group, worker group, pipeline
│       └── HttpServerHandler.java                     # Request handling, /metrics endpoint, Prometheus counter
├── prometheus.yml                                     # Scrape config (server + node_exporter)
├── netty-key.pem                                      # TLS key (for future HTTPS experiments)
├── guide_lines.txt                                    # AWS benchmarking step-by-step checklist
├── justText.txt                                       # Notes on Netty concepts, wrk usage, WSL networking
├── gradle.properties                                  # Gradle config
├── settings.gradle                                    # Project settings
├── gradlew / gradlew.bat                              # Gradle wrapper
└── gradle/                                            # Gradle wrapper JARs
```

---

## Key Concepts

| Concept | What it means here |
|---|---|
| **Boss Group** | 1 thread that only accepts new TCP connections and hands them to workers |
| **Worker Group** | N threads (= CPU cores) that handle all read/write I/O on accepted connections |
| **Channel** | A Netty abstraction over a TCP connection |
| **Pipeline** | An ordered chain of handlers that a request passes through (codec → your handler) |
| **Event Loop** | A single-threaded loop that processes I/O events for its assigned channels — never blocks |
| **`HttpObject`** | The parent type for both `HttpRequest` (headers) and `HttpContent` (body chunks) — a single HTTP request can arrive in multiple chunks |

> **TCP connections ≠ application threads ≠ CPU workers.** Netty multiplexes thousands of connections across a small number of event loop threads.
