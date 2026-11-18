# Inside Context

A hands-on experiment to understand how LLM conversation context *actually* works under the hood — by building a stateful chat server from scratch, deliberately breaking it, and watching what happens.

## Why This Exists

Frameworks and SDKs hide a critical detail: **the model has no memory**. Every API call must include the full conversation history, and your code is responsible for managing it. This project makes that visible by stripping away every abstraction and manually constructing each request to the OpenAI API.

The goal was to answer three questions:

1. **How does the input grow?** — Token usage scales with every turn because prior messages are re-sent.
2. **What happens when you hit the wall?** — The API returns HTTP 400 (`context_length_exceeded`) and refuses to answer.
3. **Can you recover gracefully?** — Yes, by selectively trimming history while preserving the messages that matter.

## What It Does

A single-file Java HTTP server (`App.java`) that:

- Exposes a **`POST /openai`** endpoint — accepts a user prompt, maintains a per-conversation message history in a `ConcurrentHashMap`, and proxies every request to `gpt-4o-mini` with the full history attached.
- Exposes a **`POST /stuff`** endpoint — injects large dummy message pairs into a conversation to deliberately inflate token count and force a context overflow.
- **Detects context overflow** — when the API returns `context_length_exceeded`, the server automatically retries with a trimmed history: system message + first 2 messages + last 4 messages + current prompt.
- **Logs everything** — prompt tokens, completion tokens, total tokens, message count, and the raw retry payload, so you can see exactly what's happening at each step.

## The Experiment (Step by Step)

```
1.  Start a conversation
    → First call: 37 prompt tokens, 2 messages stored

2.  Inject 150 dummy message pairs via /stuff
    → 302 messages stored, ~291,040 estimated tokens

3.  Inject 150 more dummy message pairs
    → 430 messages stored, ~415,200 estimated tokens

4.  Send a real prompt ("What is my fun number?")
    → API returns HTTP 400: "maximum context length is 128000...
       your messages resulted in 226081 tokens"

5.  Automatic retry kicks in
    → 430 messages reduced to 8
    → Retry returns HTTP 200
    → Model answers: "Your fun number is 34!"
       (because that detail was in the first 2 messages that were preserved)
```

### Key Observations

| Metric | First Call | After Stuffing | After Retry |
|---|---|---|---|
| Prompt tokens | 37 | — (overflow) | 2,184 |
| Messages sent | 2 | 432 | 8 |
| HTTP status | 200 | 400 | 200 |

- **Token growth is linear** with conversation length. There's no compression or summarization — the full history is re-sent every time.
- **The rough estimate was unreliable.** `characters / 4` estimated 415,200 tokens, but the API's actual count was 226,081. The API's tokenizer is what matters.
- **The debug log was misleading.** It printed `"messages":[]` while the API reported 2,184 prompt tokens. The log line ran *before* the array was populated — a reminder that you have to debug your debugging.
- **Selective retention works.** Keeping the system message, the first 2 and last 4 messages preserved enough context for the model to recall specific details (like "fun number = 34"), while the same question failed when those messages were dropped.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Java HTTP Server                     │
│                   (JDK HttpServer :8081)                  │
│                                                          │
│  POST /openai                    POST /stuff             │
│  ┌────────────────────┐          ┌──────────────────┐    │
│  │ 1. Parse prompt     │          │ Inject N dummy   │    │
│  │ 2. Load history     │          │ message pairs    │    │
│  │ 3. Build payload    │          │ into a convo     │    │
│  │    (system + hist   │          │ to force context  │    │
│  │     + new message)  │          │ overflow          │    │
│  │ 4. Call OpenAI API  │          └──────────────────┘    │
│  │ 5. If 400 → trim   │                                  │
│  │    & retry once     │                                  │
│  │ 6. Store response   │                                  │
│  │ 7. Log token usage  │                                  │
│  └────────────────────┘                                  │
│                                                          │
│         ConcurrentHashMap<String, List<ObjectNode>>       │
│         (in-memory conversation storage)                  │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
              OpenAI Chat Completions API
                    (gpt-4o-mini)
```

## Tech Stack

| Component | Choice | Why |
|---|---|---|
| Runtime | Java 21 | No framework — raw `com.sun.net.httpserver.HttpServer` |
| JSON | Jackson (`jackson-databind` 2.20.1) | Manual JSON construction with `ObjectNode` / `ArrayNode` |
| HTTP Client | `java.net.http.HttpClient` | Built-in, no extra dependencies |
| Model | `gpt-4o-mini` | Cheap enough to experiment with, 128K context window |
| Build | Maven + Shade plugin | Single fat JAR for easy deployment |
| Storage | `ConcurrentHashMap` (in-memory) | Intentionally ephemeral — the point is to see what happens |

## Prerequisites

- **Java 21+**
- **Maven 3.7+**
- **OpenAI API key**

## Setup & Run

```bash
# 1. Clone the repo
git clone <repo-url>
cd inside_context

# 2. Set your API key
export OPENAI_API_KEY=sk-...

# 3. Build and run
mvn clean compile exec:java -Dexec.mainClass=com.insidecontext.App
```

The server starts on **port 8081**.

## API Endpoints

### `POST /openai` — Chat with context

```bash
# Start a new conversation
curl -i -X POST http://localhost:8081/openai \
  -H "Content-Type: application/json" \
  -d '{"prompt": "My fun number is 34. Remember it!"}'

# Continue the conversation (use the returned conversation_id)
curl -i -X POST http://localhost:8081/openai \
  -H "Content-Type: application/json" \
  -d '{
    "conversation_id": "<id-from-previous-response>",
    "prompt": "What is my fun number?"
  }'
```

**Request body:**
| Field | Type | Required | Description |
|---|---|---|---|
| `prompt` | string | Yes | The user's message |
| `conversation_id` | string | No | Omit to start a new conversation |

**Response:**
```json
{
  "conversation_id": "f0de379f-01e7-4ea4-9988-d79b22409c1f",
  "answer": "Your fun number is 34!"
}
```

### `POST /stuff` — Inflate a conversation (for testing)

```bash
curl -i -X POST http://localhost:8081/stuff \
  -H "Content-Type: application/json" \
  -d '{
    "conversation_id": "<id>",
    "count": 150
  }'
```

**Request body:**
| Field | Type | Required | Description |
|---|---|---|---|
| `conversation_id` | string | Yes | Target conversation |
| `count` | integer | Yes | Number of dummy message pairs to inject (0–500) |

**Response:**
```json
{
  "messages_stored": 302,
  "estimated_tokens": 291040
}
```

## Context Overflow Recovery Strategy

When the API returns `context_length_exceeded`, the server rebuilds the message array:

```
┌─────────────────────────────────────────────┐
│  Original: 430+ messages → HTTP 400         │
│                                             │
│  Retry payload:                             │
│    1. System message         (always kept)  │
│    2. First 2 history msgs   (early context)│
│    3. Last 4 history msgs    (recent context)│
│    4. Current user prompt    (the question) │
│                                             │
│  Result: 8 messages → HTTP 200              │
└─────────────────────────────────────────────┘
```

The first messages preserve foundational context (e.g., "my fun number is 34"). The last messages preserve recent conversation flow. Everything in between is dropped.

## Deployment Notes

This was tested in three environments:

| Environment | Notes |
|---|---|
| **Local** | `mvn exec:java` — works out of the box |
| **EC2** | Same JAR, same behavior — but `ConcurrentHashMap` is still in-memory, so conversations don't survive restarts |
| **Lambda** | Each invocation is a fresh container — in-memory storage is effectively empty on every cold start; needs DynamoDB, ElastiCache, or similar for persistence |

> [!IMPORTANT]
> Moving to the cloud doesn't magically give you persistent storage. The `ConcurrentHashMap` lives in process memory. For production use, you'd need a database or cache layer (DynamoDB, Redis, etc.).

## Logs

The server writes structured logs to `experiment.log`. Example output:

```
==============================
Conversation ID: f0de379f-01e7-4ea4-9988-d79b22409c1f
Prompt Tokens: 37
Completion Tokens: 21
Total Tokens: 58
Messages Stored: 2
==============================

API Error Code: context_length_exceeded
Context limit exceeded!
Rebuilding conversation history...
Original history messages: 430
Retry messages: 8
Retry HTTP Status: 200

==============================
Conversation ID: f0de379f-01e7-4ea4-9988-d79b22409c1f
Prompt Tokens: 2184
Completion Tokens: 7
Total Tokens: 2191
Messages Stored: 432
==============================
```

## Project Structure

```
inside_context/
├── src/main/java/com/insidecontext/
│   └── App.java              # The entire server — single file, ~470 lines
├── pom.xml                   # Maven config (Java 21, Jackson, Shade plugin)
├── experiment.log            # Runtime logs (token counts, retries, errors)
└── .env                      # OPENAI_API_KEY (not committed)
```

## What I Learned

1. **There is no memory.** The model doesn't "remember" anything. Your code re-sends the entire conversation on every call. If you don't send it, it's gone.

2. **Token cost is cumulative.** A 10-turn conversation doesn't cost 10× a single turn — it costs 1 + 2 + 3 + ... + 10 = 55× the input of the first turn (roughly). Every prior message is re-processed.

3. **Estimation ≠ reality.** `characters / 4` is a ballpark. The API's BPE tokenizer produces a different count. Always trust the API's `usage` field.

4. **Log what you send, not what you *plan* to send.** Logging the payload before populating it gave me `"messages":[]` while the API saw 2,184 tokens. The fix: log *after* serialization.

5. **Selective history trimming works.** You don't need the whole conversation. Keeping the first few and last few messages — where foundational facts and recent context live — is often enough.

6. **Cloud ≠ persistent.** Deploying to EC2 or Lambda doesn't turn a `HashMap` into a database. You still need explicit storage.

## License

This is an experiment for learning purposes. Use it however you like.

