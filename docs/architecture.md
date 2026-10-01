---
title: Architecture
description: Request lifecycle, config resolution, model resolution, server check, facts, conversation history, model listing, and tests
---

# Architecture

## Request lifecycle

```mermaid
sequenceDiagram
    participant U as Shell
    participant A as ask.ps1
    participant C as ~/.ask.json
    participant H as history.json
    participant O as Ollama /api/chat

    U->>A: ask explain CTAD -Model codellama:7b
    A->>C: load defaults
    C-->>A: model, host, port, system
    A->>A: CLI args override defaults
    A->>H: load prior turns (if history on, unless -NoHistory)
    H-->>A: [{role, content}, ...]
    A->>A: join question words
    A->>A: build JSON body (optional system + history + question)
    A->>O: POST /api/chat {stream:true}
    loop each NDJSON chunk
        O-->>A: {message:{content:"..."}, done:false}
        A-->>U: render each completed line as Markdown
    end
    O-->>A: {done:true}
    A-->>U: render the last line
    A->>H: append {user, assistant} turn
```

## Config resolution

Every setting follows the same CLI-overrides-config-overrides-default chain:

```mermaid
flowchart TD
    A["Parameter passed?"] -->|yes| B["Use CLI value"]
    A -->|no| C["~/.ask.json value?"]
    C -->|yes| D["Use config value"]
    C -->|no| E["Use built-in default"]
    B --> F["Effective setting"]
    D --> F
    E --> F
```

## Model capabilities and tools

`ask.ps1` always uses `/api/chat`. It asks `/api/show` for the model's capabilities (cached for a day in `~/.ask_model_cache.json`) to catch a missing or non-text model early and to decide how tools are offered. Tools are off unless `-Tools` or `"tools": true`; then `tools_model` is used if set, and the loop in `ask-tools.ps1` takes over:

```mermaid
flowchart TD
    Q["Question + history"] --> T{"Tools on?"}
    T -->|no| S["POST /api/chat stream:true\nrender Markdown line by line"]
    T -->|yes| C{"Model has native\ntools capability?"}
    C -->|yes| N["POST /api/chat with tools[]"]
    C -->|no| P["TOOL {...} protocol in system prompt\n(warns: set tools_model)"]
    N --> L["tool loop, max 8 rounds"]
    P --> L
    L --> R{"run_command?"}
    R -->|yes| Y["ask y/N first"]
    L --> A["final answer rendered"]
```

## Conversation history

By default, `ask` remembers the conversation. Each call appends your question and the model's reply to `~/.ask_conversation_state.json`, capped at the last 20 exchanges (40 messages), and prepends that history to the next request. Turns are sent to `/api/chat` with their real roles, so the model treats earlier questions as answered and replies only to the latest; re-asking a question drops its earlier exchange. After `history_idle_minutes` (default 30) without a question, the next one starts a fresh thread. Set `"history": false` in `~/.ask.json` to disable history by default.

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

## Model resolution

`-Model` is a switch, so a bare `ask -model` can show the current model. When there is a question, the override tag is its first or last word, checked against `/api/tags`:

```mermaid
flowchart TD
    S["ask ... -Model ..."] --> Q{"Any question words?"}
    Q -->|"no: ask -model / ask --model"| SHOW["print current model\n(and tools_model if set)"]
    Q -->|yes| T["GET /api/tags"]
    T --> F{"first word an\ninstalled tag?"}
    F -->|yes| USE["use it for this call,\ndrop it from the question"]
    F -->|no| L{"last word an\ninstalled tag?"}
    L -->|yes| USE
    L -->|no| ERR["error: -Model needs an\ninstalled tag (see ask -Models)"]
    N["no -Model"] --> TO{"tools on and\ntools_model set?"}
    TO -->|yes| TM["tools_model"]
    TO -->|no| DM["model"]
```

## Server check

`ask-check.ps1` just runs `ask.ps1 -Check`, so `ask-check` and `ask --check` share one implementation:

```mermaid
flowchart TD
    A["ask-check"] -->|"thin wrapper"| C["ask -Check"]
    B["ask --check"] --> C
    C --> R["resolve host/port\n(config or CLI)"]
    R --> T["GET /api/tags"]
    T -->|unreachable| F["[FAIL] reason + restart hint\nexit 1"]
    T -->|ok| L["[OK] list models\n* current, - others"]
    L --> W{"current model\ninstalled?"}
    W -->|no| WARN["[WARN] ollama pull hint"]
    W -->|yes| OK["exit 0"]
    WARN --> OK
```

## Facts

Statements are caught locally before any model call and saved to `facts` in `~/.ask.json`; questions get every fact in their system prompt:

```mermaid
flowchart TD
    I["ask &lt;words&gt;"] --> NF{"-NoFacts?"}
    NF -->|yes| Q["send to the model as a question"]
    NF -->|no| R{"starts with\nremember (that)?"}
    R -->|yes| SAVE
    R -->|no| QM{"ends with ?, starts with a\nquestion/request word, or mentions\nhelp/bug/error/failing...?"}
    QM -->|yes| Q
    QM -->|no| FP{"first person?\nmy X is ... / I live, work,\nam, have, use, prefer ..."}
    FP -->|no| Q
    FP -->|yes| SAVE["save to facts in ~/.ask.json\n(my X is ... replaces an older one)"]
    SAVE --> ACK["Noted (fact n) -- no model call"]
    Q --> SYS["system prompt carries every fact\nso the model can reason with them"]
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

## Tests

`tests/run.ps1` runs 100 Pester tests: unit tests on functions lifted out of `ask.ps1`'s AST, and integration tests that run `ask.ps1` as a command against a scripted fake Ollama, each in its own `ASK_HOME`:

```mermaid
flowchart LR
    R["tests/run.ps1"] --> P["Pester 5"]
    P --> U["Unit.Tests.ps1\n55 tests"]
    P --> I["Integration.Tests.ps1\n45 tests"]
    U -->|"functions lifted\nfrom the AST"| A1["ask.ps1 functions\n+ ask-tools.ps1"]
    I -->|"pwsh -File ask.ps1 ...\nASK_HOME = temp dir\nASK_NO_LAUNCH = 1"| A2["ask.ps1 / ask-check.ps1\nas a command"]
    A2 -->|HTTP| M["MockOllama.ps1\nHttpListener on localhost\nscripted replies"]
    M -->|"request log"| I
```

## Related

- [Overview](.) — install, usage, parameters
