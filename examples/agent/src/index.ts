import { startRunner } from "@dis/sdk";
import { Agent } from "./agent.js";

await startRunner({
  engineUrl: process.env["DIS_ENGINE_URL"] ?? "ws://localhost:7070/runner",
  actors: [Agent],
});
