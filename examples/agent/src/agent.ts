// Example DurableInference actor. Exactly what a user would write against
// @dis/sdk. Nothing here is magic — lifecycle hooks are plain async
// methods; all capabilities arrive as `this.ctx.*` and `this.ai.*`.

import {
  DurableInference,
  type Connection,
  type ScheduleInfo,
  type StartInfo,
  type StopInfo,
} from "@dis/sdk";

const MODEL = "llama-3.2-1b";

interface Input {
  system: string;
}

interface State {
  system: string;
  turns: number;
  createdAt: number;
  lastActiveAt: number;
}

export class Agent extends DurableInference<Input, State> {
  override async onStart({ reason, input }: StartInfo<Input>): Promise<void> {
    await this.ctx.blockConcurrencyWhile(async () => {
      // One await — returns a hydrated Proxy, no $ready dance.
      this.state = await this.ctx.initialState<State>({
        system: "",
        turns: 0,
        createdAt: 0,
        lastActiveAt: 0,
      });

      await this.ai.loadModel(MODEL);

      if (reason === "create") {
        this.state.system = input!.system;
        this.state.createdAt = Date.now();
        await this.ctx.sql.exec(
          `CREATE TABLE IF NOT EXISTS turns (
             idx INTEGER PRIMARY KEY, role TEXT, text TEXT, ts INTEGER
           )`,
        );
      }
    });

    this.ctx.broadcast(JSON.stringify({ kind: "hello" }));

    await this.ctx.schedule({ every: 5 * 60 }, "rollupStats", undefined,
                            { idempotentKey: "rollup" });
    await this.ctx.schedule("0 3 * * *", "gcOldTurns", { keepDays: 7 },
                            { idempotentKey: "gc" });
  }

  override async onStop({ reason }: StopInfo): Promise<void> {
    this.ctx.broadcast(JSON.stringify({ kind: "bye", reason }));
    this.state.lastActiveAt = Date.now();
    await this.state.$flush();
  }

  override async onRequest(req: Request): Promise<Response> {
    const prompt = await req.text();

    // Plain mutation — auto-persists.
    this.state.turns += 1;

    await this.ctx.sql.exec(
      `INSERT INTO turns(role, text, ts) VALUES (?, ?, ?)`,
      ["user", prompt, Date.now()],
    );

    const stream = this.ai.generate(MODEL, prompt, {
      maxTokens: 256,
      temperature: 0.7,
    });
    const [toClient, toDb] = stream.tee();
    this.recordReply(toDb).catch(console.error);

    return new Response(toClient, {
      headers: { "content-type": "text/event-stream" },
    });
  }

  override async onMessage(connection: Connection, msg: string | Uint8Array) {
    const text = typeof msg === "string" ? msg : new TextDecoder().decode(msg);

    // Everyone *except* the sender sees a "typing" notice.
    this.ctx.broadcast(
      JSON.stringify({ kind: "typing", from: connection.id }),
      [connection.id],
    );

    const stream = this.ai.generate(MODEL, text, { maxTokens: 256 });
    for await (const tok of stream) {
      this.ctx.broadcast(JSON.stringify({ kind: "token", text: tok.text }));
    }
    this.ctx.broadcast(JSON.stringify({ kind: "done" }));
  }

  // ── Scheduled callbacks ──────────────────────────────────────────────

  async rollupStats(_payload: undefined, info: ScheduleInfo): Promise<void> {
    console.log(
      "[rollup]",
      this.ctx.id,
      "turns:",
      this.state.turns,
      "attempt:",
      info.attempt,
    );
  }

  async gcOldTurns(args: { keepDays: number }): Promise<void> {
    const cutoff = Date.now() - args.keepDays * 86_400_000;
    await this.ctx.sql.exec("DELETE FROM turns WHERE ts < ?", [cutoff]);
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  private async recordReply(stream: ReadableStream<Uint8Array>): Promise<void> {
    const reader = stream.getReader();
    let text = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      text += new TextDecoder().decode(value);
    }
    await this.ctx.sql.exec(
      `INSERT INTO turns(role, text, ts) VALUES (?, ?, ?)`,
      ["assistant", text, Date.now()],
    );
  }
}
