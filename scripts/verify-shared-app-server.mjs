#!/usr/bin/env node
/**
 * 共有 app-server 検証スクリプト
 *
 * 検証内容:
 *   1. codex app-server を WebSocket モードで起動
 *   2. Client A (CC Pocket役) が接続 → thread/start → turn/start
 *   3. Client B (TUI役) が接続 → thread/loaded/list で進行中スレッドを発見
 *   4. Client B が thread/resume でそのスレッドに合流
 *   5. Client B がイベント (item/*, turn/*) を受信できるか確認
 *
 * 使い方:
 *   node scripts/verify-shared-app-server.mjs
 *
 * 前提:
 *   - codex CLI がパスに存在すること
 *   - OPENAI_API_KEY が設定されていること (thread/start に必要)
 */

import { WebSocket } from "ws";
import { spawn } from "node:child_process";

const PORT = 19876;
const WS_URL = `ws://127.0.0.1:${PORT}`;
const CWD = process.env.HOME;

// ─── helpers ───

let nextId = 1;

function createClient(name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    const pending = new Map(); // id -> { resolve, reject }
    const notifications = [];

    ws.on("open", () => resolve({ ws, pending, notifications, name }));
    ws.on("error", reject);
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.id != null && pending.has(msg.id)) {
        const { resolve: res, reject: rej } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) rej(msg.error);
        else res(msg.result);
      } else if (msg.method) {
        notifications.push(msg);
      }
    });
  });
}

function request(client, method, params = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    client.pending.set(id, { resolve, reject });
    client.ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => {
      if (client.pending.has(id)) {
        client.pending.delete(id);
        reject(new Error(`timeout: ${method}`));
      }
    }, 15_000);
  });
}

function notify(client, method, params = {}) {
  client.ws.send(JSON.stringify({ method, params }));
}

async function initialize(client) {
  const result = await request(client, "initialize", {
    clientInfo: {
      name: `ccpocket_verify_${client.name}`,
      title: `Verify ${client.name}`,
      version: "0.0.1",
    },
  });
  notify(client, "initialized");
  return result;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function log(label, msg) {
  console.log(`[${label}] ${msg}`);
}

// ─── main ───

async function main() {
  // 1. Start app-server
  log("server", `Starting codex app-server on ${WS_URL} ...`);
  const server = spawn("codex", ["app-server", "--listen", `ws://127.0.0.1:${PORT}`], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env },
  });

  let serverReady = false;
  server.stderr.on("data", (chunk) => {
    const text = chunk.toString();
    if (text.includes("listening") || text.includes("ready") || text.includes("bound")) {
      serverReady = true;
    }
    if (process.env.VERBOSE) process.stderr.write(`  [server:err] ${text}`);
  });
  server.stdout.on("data", (chunk) => {
    if (process.env.VERBOSE) process.stdout.write(`  [server:out] ${chunk}`);
  });

  // Wait for server readiness via /readyz
  log("server", "Waiting for readyz ...");
  for (let i = 0; i < 30; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/readyz`);
      if (res.ok) {
        serverReady = true;
        break;
      }
    } catch {
      // not ready yet
    }
    await sleep(500);
  }
  if (!serverReady) {
    server.kill();
    throw new Error("app-server did not become ready");
  }
  log("server", "Ready!");

  try {
    // 2. Client A connects and starts a thread
    log("A", "Connecting ...");
    const clientA = await createClient("A");
    await initialize(clientA);
    log("A", "Initialized");

    log("A", "thread/start ...");
    const startResult = await request(clientA, "thread/start", {
      cwd: CWD,
      experimentalRawEvents: false,
      persistExtendedHistory: false,
    });
    const threadId = startResult.thread.id;
    log("A", `Thread created: ${threadId}`);
    log("A", `Thread status: ${JSON.stringify(startResult.thread.status)}`);

    // 3. Client B connects and discovers active threads
    log("B", "Connecting ...");
    const clientB = await createClient("B");
    await initialize(clientB);
    log("B", "Initialized");

    log("B", "thread/loaded/list ...");
    const loadedList = await request(clientB, "thread/loaded/list", {});
    log("B", `Loaded threads: ${JSON.stringify(loadedList.data)}`);

    const found = loadedList.data.includes(threadId);
    log("B", found
      ? `✅ Found Client A's thread in loaded list!`
      : `❌ Client A's thread NOT found in loaded list`
    );

    // 4. Client A starts a turn first (to force rollout flush)
    log("A", "turn/start ...");
    const turnResult = await request(clientA, "turn/start", {
      threadId,
      input: [{ type: "text", text: "Say exactly: HELLO_SHARED_SESSION", text_elements: [] }],
    });
    log("A", `Turn started: ${turnResult.id}`);

    // Wait for turn to complete and rollout to flush
    log("A", "Waiting for turn completion (8s) ...");
    await sleep(8000);

    // Check rollout file exists
    log("B", `thread/read ${threadId} ...`);
    try {
      const readResult = await request(clientB, "thread/read", { threadId, includeTurns: false });
      log("B", `thread/read: status=${JSON.stringify(readResult.thread.status)}, path=${readResult.thread.path}`);
    } catch (err) {
      log("B", `thread/read failed: ${JSON.stringify(err)}`);
    }

    // 5. Client B resumes (joins) the thread
    log("B", `thread/resume ${threadId} ...`);
    const resumeResult = await request(clientB, "thread/resume", {
      threadId,
      persistExtendedHistory: false,
    });
    log("B", `✅ Resumed thread: ${resumeResult.thread.id}`);
    log("B", `Thread status: ${JSON.stringify(resumeResult.thread.status)}`);

    // 6. Client A starts another turn, Client B should receive events
    log("A", "turn/start (2nd) ...");
    const turnResult2 = await request(clientA, "turn/start", {
      threadId,
      input: [{ type: "text", text: "Say exactly: SECOND_MESSAGE", text_elements: [] }],
    });
    log("A", `Turn started: ${turnResult2.id}`);

    // Wait for events to flow to Client B
    log("B", "Waiting for events (5s) ...");
    await sleep(5000);

    const bEvents = clientB.notifications;
    log("B", `Received ${bEvents.length} notifications`);

    const eventMethods = [...new Set(bEvents.map((n) => n.method))];
    log("B", `Event types: ${eventMethods.join(", ")}`);

    const hasItemEvents = bEvents.some(
      (n) => n.method?.startsWith("item/") || n.method?.startsWith("turn/")
    );
    log("B", hasItemEvents
      ? "✅ Client B received item/turn events from Client A's turn!"
      : "❌ Client B did NOT receive item/turn events"
    );

    // Summary
    console.log("\n=== Summary ===");
    console.log(`Thread discovery (loaded/list):  ${found ? "✅ PASS" : "❌ FAIL"}`);
    console.log(`Thread resume (join):            ✅ PASS`);
    console.log(`Event broadcast to 2nd client:   ${hasItemEvents ? "✅ PASS" : "❌ FAIL"}`);

    // Cleanup
    clientA.ws.close();
    clientB.ws.close();
  } finally {
    server.kill();
    log("server", "Stopped");
  }
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
