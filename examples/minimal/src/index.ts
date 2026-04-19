import { startRunner } from "@dis/sdk";
import { EchoActor } from "./echo.js";

const handle = await startRunner({
  engineUrl: process.env["DIS_ENGINE_URL"] ?? "ws://localhost:7070/runner",
  actors: [EchoActor],
});

await handle.ready();
console.log(`[runner] connected; actors=${handle.actorNames().join(",")}`);
