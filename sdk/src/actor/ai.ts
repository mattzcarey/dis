// AiApi impl — RPCs into the engine, which proxies to dis-infer over the
// unix socket. The heavy lifting (prefill/decode, KV snapshot) lives in
// dis-infer; this is just a thin client.

import { Op, type Tunnel } from "../tunnel.js";
import type {
  AiApi,
  GenerateOpts,
  LoadModelOpts,
  ModelInfo,
  Token,
  TokenStream,
} from "../types.js";

export class AiImpl implements AiApi {
  constructor(
    private readonly tunnel: Tunnel,
    private readonly sessionId: string,
  ) {}

  models(): Promise<ModelInfo[]> {
    return this.tunnel.request<ModelInfo[]>(Op.Models, {});
  }

  loadModel(modelId: string, opts?: LoadModelOpts): Promise<void> {
    return this.tunnel.request<void>(Op.LoadModel, {
      modelId,
      timeoutMs: opts?.timeoutMs ?? 120_000,
      nGpuLayers: opts?.nGpuLayers ?? -1,
    });
  }

  generate(modelId: string, prompt: string, opts?: GenerateOpts): TokenStream {
    const src = this.tunnel.requestStream<Token>(Op.Generate, {
      sid: this.sessionId,
      modelId,
      prompt,
      opts,
    });
    return wrapTokenStream(src);
  }

  generateRaw(
    modelId: string,
    tokens: readonly number[],
    opts?: GenerateOpts,
  ): TokenStream {
    const src = this.tunnel.requestStream<Token>(Op.GenerateRaw, {
      sid: this.sessionId,
      modelId,
      tokens,
      opts,
    });
    return wrapTokenStream(src);
  }

  tokenize(modelId: string, text: string): Promise<number[]> {
    return this.tunnel.request<number[]>(Op.Tokenize, { modelId, text });
  }

  resetContext(modelId: string): Promise<void> {
    return this.tunnel.request<void>(Op.ResetContext, {
      sid: this.sessionId,
      modelId,
    });
  }
}

// ─── TokenStream wrapper ──────────────────────────────────────────────
//
// Engine sends us a ReadableStream<Token>. We expose it as:
//   1. ReadableStream<Uint8Array> — bytes for `new Response(stream)`
//   2. AsyncIterable<Token> — for `for await (const t of stream)`
//   3. .asText(): AsyncIterable<string> — for `for await (const s of ...)`
//
// Internally we tee the source so the two consumer shapes never race.

function wrapTokenStream(src: ReadableStream<Token>): TokenStream {
  const [forBytes, forTokens] = src.tee();
  const encoder = new TextEncoder();

  const byteStream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const reader = forBytes.getReader();
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          controller.enqueue(encoder.encode(value.text));
        }
        controller.close();
      } catch (e) {
        controller.error(e);
      } finally {
        reader.releaseLock();
      }
    },
  }) as TokenStream;

  // Attach AsyncIterable<Token>
  Object.defineProperty(byteStream, Symbol.asyncIterator, {
    value(): AsyncIterator<Token> {
      const reader = forTokens.getReader();
      return {
        async next() {
          const { value, done } = await reader.read();
          return done
            ? { value: undefined as unknown as Token, done: true }
            : { value: value!, done: false };
        },
        async return() {
          reader.releaseLock();
          return { value: undefined as unknown as Token, done: true };
        },
      };
    },
    writable: false,
  });

  // Attach .asText()
  Object.defineProperty(byteStream, "asText", {
    value(): AsyncIterable<string> {
      const reader = forTokens.getReader();
      return {
        [Symbol.asyncIterator]() {
          return {
            async next() {
              const { value, done } = await reader.read();
              return done
                ? { value: undefined as unknown as string, done: true }
                : { value: value!.text, done: false };
            },
          };
        },
      };
    },
    writable: false,
  });

  return byteStream;
}
