# dis

An experiment in durable inference servers.

Write a class, get a long-lived WebSocket endpoint with its own
colocated LLM (backed by [llama.cpp][]) — in the style of the Actor
model / [Cloudflare Durable Objects][do]. Each session is a persistent,
stateful actor whose KV cache, in-memory state, and user code stay
resident between messages on the same WebSocket.

```ts
import { DurableInference, type Connection } from "@dis/sdk";

export class ChatActor extends DurableInference {
  override readonly name = "chat";

  override async onMessage(connection: Connection, msg: string) {
    for await (const tok of this.ai.generate("llama-3.2-1b", msg))
      connection.send(JSON.stringify({ type: "delta", text: tok.text }));
  }
}
```

See [`SPEC.md`](SPEC.md) for the design and [`TODO.md`](TODO.md) for
what's next.

[llama.cpp]: https://github.com/ggml-org/llama.cpp
[do]: https://developers.cloudflare.com/durable-objects/
