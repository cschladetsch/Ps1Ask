---
title: Architecture
description: Request lifecycle, config resolution, conversation history, and model listing
---

# Architecture

## Request lifecycle

```mermaid
sequenceDiagram
    participant U as Shell
    participant A as ask.ps1
    participant C as config.json
    participant H as history.json
    participant O as Ollama /api/chat

    U->>A: ask explain CTAD -Model codellama:7b
    A->>C: load defaults
    C-->>A: model, host, port, system
    A->>A: CLI args override defaults
    A->>H: load prior turns (if history on, unless -NoHistory)
    H-->>A: [{role, content}, ...]
    A->>A: join question words
    A->>A: build JSON body (system + history + reply-to-last note + question)
    A->>O: POST /api/chat {stream:true}
    loop each NDJSON chunk
        O-->>A: {message:{content:"..."}, done:false}
        A-->>U: Write-Host -NoNewline token
    end
    O-->>A: {done:true}
    A-->>U: newline
    A->>H: append {user, assistant} turn
```

## Config resolution

Every setting follows the same CLI-overrides-config-overrides-default chain:

```mermaid
flowchart TD
    A["Parameter passed?"] -->|yes| B["Use CLI value"]
    A -->|no| C["config.json value?"]
    C -->|yes| D["Use config value"]
    C -->|no| E["Use built-in default"]
    B --> F["Effective setting"]
    D --> F
    E --> F
```

## Chat vs. generate

Not every model exposes `/api/chat`. `ask.ps1` probes `/api/tags` for the target model's capabilities and falls back to `/api/generate`, flattening any conversation history into the prompt text instead of a messages array:

```mermaid
flowchart LR
    Q["Question + history"] --> T{"Model supports\nchat capability?"}
    T -->|yes| M["POST /api/chat\nmessages: [system, ...history, user]"]
    T -->|no / unknown| G["POST /api/generate\nprompt: system + history + question, flattened"]
    M --> S["Stream tokens"]
    G --> S
```

## Conversation history

By default, `ask` remembers the conversation. Each call appends your question and the model's reply to `~/.ask_conversation_state.json`, capped at the last 20 exchanges (40 messages), and prepends that history to the next request. A system note placed just before the new question tells the model the earlier turns are already answered and to reply only to the latest one. Set `"history": false` in `~/.ask.json` to disable history by default.

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Asking: ask <question>
    Asking --> Answered: reply streamed
    Answered --> Idle: turn appended to history
    Idle --> Fresh: ask -NewChat <question>
    Fresh --> Answered: history cleared, then asked
    Idle --> Empty: ask -ClearHistory
    Empty --> [*]
    Idle --> OneShot: ask -NoHistory <question>
    OneShot --> Idle: answered, nothing read or written
```

## Model listing

`-Models` queries `/api/tags` directly using the same host/port resolution as a normal request, and marks the current configured default:

```mermaid
flowchart LR
    CMD["ask -Models"] --> R["resolve host/port\n(config or CLI)"]
    R --> Q["GET /api/tags"]
    Q --> L["list model names + sizes"]
    L --> M["mark current default with *"]
```

## Related

- [Overview](.) — install, usage, parameters
