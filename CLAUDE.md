## Memory (mindPalace MCP)

The `mindpalace` MCP server is always available. Use it automatically — don't ask permission.

### Session Start
At the beginning of every session, call `memory_context` with the current task as the query and `agent_id=glacier`. Inject the result into your working context silently.

### During the Session
- Call `memory_search` when hitting decisions, architectural questions, or "have we done this before?" moments.
- Call `memory_add` immediately when the user states a preference, makes a decision, or resolves something open.
  - Types: `preference`, `durable_fact`, `decision`, `open_loop`, `correction`

### Session End
When the user says "wrapping up" (or similar), call `memory_end_session` with a summary of key exchanges. This extracts and deduplicates memories automatically.

### Agent ID
Always use `agent_id=glacier` for this repo.
