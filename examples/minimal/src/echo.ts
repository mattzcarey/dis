// Minimal demo actor — mirrors OpenAI Realtime/Responses API shape.
//
// Client protocol:
//   client → { "type": "response.create", "input": "tell me a joke" }
//   server → { "type": "response.text.delta", "delta": "why" }
//   server → { "type": "response.text.delta", "delta": " did" }
//   ...
//   server → { "type": "response.done" }

import {
  DurableInference,
  type Connection,
  type StartInfo,
  type StopInfo,
} from "@dis/sdk";

interface ResponseCreate {
  type: "response.create";
  input: string;
  /** Optional cap on tokens generated. */
  max_output_tokens?: number;
}

export class EchoActor extends DurableInference<unknown, Record<string, never>> {
  override readonly name = "echo";

  override async onStart({ reason }: StartInfo<unknown>): Promise<void> {
    console.log(`[echo] onStart sid=${this.ctx.id} reason=${reason}`);
  }

  override async onStop({ reason }: StopInfo): Promise<void> {
    console.log(`[echo] onStop reason=${reason}`);
  }

  override async onMessage(connection: Connection, msg: string | Uint8Array): Promise<void> {
    const text = typeof msg === "string" ? msg : new TextDecoder().decode(msg);

    let event: ResponseCreate;
    try {
      event = JSON.parse(text);
    } catch {
      connection.send(JSON.stringify({ type: "error", message: "invalid json" }));
      return;
    }

    if (event.type !== "response.create") {
      connection.send(JSON.stringify({ type: "error", message: `unknown type: ${event.type}` }));
      return;
    }

    console.log(`[echo] response.create cid=${connection.id.slice(0, 8)} input='${event.input.slice(0, 40)}...'`);

    const stream = this.ai.generate("stub", event.input, {
      ...(event.max_output_tokens !== undefined && { maxTokens: event.max_output_tokens }),
    });

    let tokens = 0;
    for await (const tok of stream) {
      connection.send(JSON.stringify({ type: "response.text.delta", delta: tok.text }));
      tokens++;
    }
    connection.send(JSON.stringify({ type: "response.done", tokens }));
    console.log(`[echo] response.done tokens=${tokens}`);
  }
}
