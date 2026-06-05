# Examples

Runnable scripts that exercise `parse-stack-next` against a live Parse Server.
Each file is self-contained and reads its configuration from environment
variables. Start here:

| Script | Demonstrates | Needs |
|---|---|---|
| [`basic_server.rb`](basic_server.rb) | Privileged (master-key) setup: define models, push schema with `auto_upgrade!`, full CRUD + queries with a `belongs_to`. | app id, REST key, **master key** |
| [`basic_client.rb`](basic_client.rb) | Unprivileged client (no master key): login/signup, `with_session`, and a row-level **ACL enforcement** demo (the owner reads a record; an anonymous caller gets `nil`). | app id, REST key |
| [`live_query_listener.rb`](live_query_listener.rb) | Interactive LiveQuery console: subscribes scoped to a user's session token and prints create / update / delete events until Ctrl-C — you only "hear" what that user may read. | app id, REST key, LiveQuery URL |
| [`rag_chatbot.rb`](rag_chatbot.rb) | Retrieval-augmented generation: managed `embed`, `agent_searchable`, `semantic_search` via `Parse::Agent`, plus an OpenAI/Anthropic generation add-in. | app id, REST key, master key, `OPENAI_API_KEY` (+ Atlas) |
| [`transaction_example.rb`](transaction_example.rb) | Atomic multi-object operations via `Parse::Object.transaction`. | app id, REST key |

## Common setup

All scripts read a Parse connection from the environment:

```bash
export PARSE_SERVER_URL=http://localhost:1337/parse
export PARSE_APP_ID=your-app-id
export PARSE_REST_KEY=your-rest-api-key
export PARSE_MASTER_KEY=your-master-key   # server-side scripts only
```

Then run any script with the gem on the load path:

```bash
ruby -Ilib examples/basic_server.rb
```

## Suggested order

1. **`basic_server.rb`** — defines and provisions the `Artist`, `Song`, and
   `Post` classes the other scripts use. Run it first.
2. **`basic_client.rb`** — see how the same SDK behaves without the master key,
   and watch Parse Server enforce a row-level ACL.
3. **`live_query_listener.rb`** — leave it running, then create/update/destroy
   `Post`s from another terminal (or the dashboard) and watch them stream in.
4. **`rag_chatbot.rb`** — requires an Atlas-backed server and an embedding key;
   see [`../docs/atlas_vector_search_guide.md`](../docs/atlas_vector_search_guide.md)
   for the vector-search setup.

> Each script's header comment lists the exact environment variables and any
> prerequisites (e.g. `basic_client.rb` needs the `Post` class to already
> exist, which `basic_server.rb` provisions).
