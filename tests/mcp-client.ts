// Scripted MCP client for `fast-ios mcp`. Drives initialize, tools/list and a
// tools/call per tool over stdio, and checks every response: the JSON-RPC
// envelope, each tool listing, and each structuredContent against the tool's
// outputSchema. Prints a transcript; exits 1 on the first failed check.
//
//   bun run tests/mcp-client.ts --bin .build/debug/fast-ios --set <device set> \
//     --simulator <UDID in that set> --app <built .app>
//
// The simulator must be one you created: the script slims it, boots it,
// measures it and restores it to stock. The lease checks create one more
// simulator (fast-ios-lease-*) in the same set and shut it down; delete it
// afterwards with `xcrun simctl --set <set> delete <udid>`.

import { spawn } from "bun";

const argv = process.argv.slice(2);
const opt = (name: string) => {
  const i = argv.indexOf(`--${name}`);
  if (i < 0 || i + 1 >= argv.length) throw new Error(`missing --${name}`);
  return argv[i + 1];
};
const bin = opt("bin"), deviceSet = opt("set"), simulator = opt("simulator"), app = opt("app");

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
type Schema = { [k: string]: any };

// JSON Schema subset: type (string or list), properties, required,
// additionalProperties (false or a schema), items. Written apart from the
// Swift validator so the two check each other.
function validate(v: Json, s: Schema, path = "$"): string[] {
  const errs: string[] = [];
  const typeOf = (x: Json) =>
    x === null ? "null" : Array.isArray(x) ? "array" : typeof x === "number" ? (Number.isInteger(x) ? "integer" : "number") : typeof x;
  if (s.type) {
    const allowed: string[] = Array.isArray(s.type) ? s.type : [s.type];
    const t = typeOf(v);
    if (!allowed.includes(t) && !(t === "integer" && allowed.includes("number"))) {
      return [`${path}: expected ${allowed.join("|")}, got ${t}`];
    }
  }
  if (v && typeof v === "object" && !Array.isArray(v)) {
    for (const k of s.required ?? []) if (!(k in v)) errs.push(`${path}.${k}: required`);
    for (const [k, x] of Object.entries(v)) {
      if (s.properties?.[k]) errs.push(...validate(x, s.properties[k], `${path}.${k}`));
      else if (s.additionalProperties === false) errs.push(`${path}.${k}: not in schema`);
      else if (typeof s.additionalProperties === "object") errs.push(...validate(x, s.additionalProperties, `${path}.${k}`));
    }
  }
  if (Array.isArray(v) && s.items) v.forEach((x, i) => errs.push(...validate(x, s.items, `${path}[${i}]`)));
  return errs;
}

const proc = spawn([bin, "mcp", "--set", deviceSet], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
const reader = proc.stdout.getReader();
let buffer = "";
const decoder = new TextDecoder();

async function readMessage(): Promise<any> {
  for (;;) {
    const nl = buffer.indexOf("\n");
    if (nl >= 0) {
      const line = buffer.slice(0, nl);
      buffer = buffer.slice(nl + 1);
      return JSON.parse(line); // throws if the server printed anything but JSON
    }
    const { value, done } = await reader.read();
    if (done) throw new Error("server closed stdout");
    buffer += decoder.decode(value, { stream: true });
  }
}

let nextId = 1, failures = 0;
const short = (x: unknown, n = 600) => {
  const s = JSON.stringify(x);
  return s.length > n ? `${s.slice(0, n)}… (${s.length} chars)` : s;
};
function check(ok: boolean, what: string) {
  console.log(`   ${ok ? "PASS" : "FAIL"} ${what}`);
  if (!ok) failures++;
}

async function request(method: string, params?: Json) {
  const id = nextId++;
  const msg = { jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) };
  console.log(`→ ${short(msg)}`);
  const t0 = performance.now();
  proc.stdin.write(JSON.stringify(msg) + "\n");
  proc.stdin.flush();
  const reply = await readMessage();
  console.log(`← (${((performance.now() - t0) / 1000).toFixed(1)} s) ${short(reply)}`);
  check(reply.jsonrpc === "2.0" && reply.id === id && ("result" in reply) !== ("error" in reply), "JSON-RPC 2.0 envelope, matching id, result xor error");
  return reply;
}

function notify(method: string) {
  const msg = { jsonrpc: "2.0", method };
  console.log(`→ ${short(msg)} (notification, no reply expected)`);
  proc.stdin.write(JSON.stringify(msg) + "\n");
  proc.stdin.flush();
}

// 1. Handshake.
const init = await request("initialize", {
  protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fast-ios-test", version: "1" },
});
check(init.result?.protocolVersion === "2025-06-18", "initialize echoes the requested protocolVersion");
check(typeof init.result?.capabilities?.tools === "object", "initialize declares the tools capability");
check(init.result?.serverInfo?.name === "fast-ios", "serverInfo.name is fast-ios");
notify("notifications/initialized");
const ping = await request("ping");
check(JSON.stringify(ping.result) === "{}", "ping returns {} (and the notification got no reply)");

// 2. tools/list.
const list = await request("tools/list");
const tools: any[] = list.result?.tools ?? [];
const byName = new Map(tools.map((t) => [t.name, t]));
for (const t of tools) {
  check(typeof t.name === "string" && typeof t.description === "string" && t.description.length > 20
    && t.inputSchema?.type === "object" && t.outputSchema?.type === "object",
    `tools/list entry ${t.name}: name, description, object inputSchema and outputSchema`);
}
console.log(`   tools: ${tools.map((t) => t.name).join(", ")}`);

// 3. One tools/call per tool (plus the error paths).
async function call(name: string, args: Record<string, Json>, expectError = false) {
  const tool = byName.get(name);
  if (tool) {
    const inErrs = validate(args, tool.inputSchema, "arguments");
    if (!expectError) check(inErrs.length === 0, `${name} arguments match inputSchema ${inErrs.join("; ")}`);
  }
  const reply = await request("tools/call", { name, arguments: args });
  const r = reply.result;
  if (expectError) return reply;
  check(r?.isError === false, `${name}: isError false`);
  check(r?.content?.[0]?.type === "text" && JSON.stringify(JSON.parse(r.content[0].text)) === JSON.stringify(r.structuredContent),
    `${name}: text content is the same JSON as structuredContent`);
  const errs = validate(r?.structuredContent, tool.outputSchema);
  check(errs.length === 0, `${name}: structuredContent matches outputSchema ${errs.slice(0, 5).join("; ")}`);
  return r?.structuredContent;
}

const catalog = await call("catalog", {});
check(catalog.categories.length > 0 && catalog.slimmableCount > 100, `catalog: ${catalog.categories.length} categories, ${catalog.slimmableCount} services`);

const profile = await call("profile", { app });
check(profile.profile.disable.length + Object.keys(profile.profile.keep).length === profile.catalogCount,
  `profile: keep ${Object.keys(profile.profile.keep).length} + disable ${profile.profile.disable.length} = catalog ${profile.catalogCount}`);

const before = await call("status", {});
check(before.simulators.some((s: any) => s.udid === simulator), "status lists the test simulator");
check(before.deviceSet !== null, `status reports the private device set ${before.deviceSet}`);

const slim = await call("slim", { simulator, app, boot: true });
check(slim.booted && slim.verified && slim.notHonoured.length === 0, `slim: booted, verified, ${slim.disabled.length} disabled`);

const measure = await call("measure", { simulator });
check(measure.processCount > 10 && measure.totalBytes > 0, `measure: ${measure.processCount} processes, ${Math.round(measure.totalBytes / 1048576)} MB`);

const after = await call("status", {});
const row = after.simulators.find((s: any) => s.udid === simulator);
check(row?.slim === true && row?.state === "Booted" && typeof row?.memoryBytes === "number", `status after slim: slim, Booted, ${row?.processes} processes`);

// heal for 3 s with nothing failing: a healing and a stopped event, no repairs.
const healed = await call("heal", { simulator, app, seconds: 3 });
check(healed.events[0]?.event === "healing" && healed.events.at(-1)?.event === "stopped" && healed.repaired === 0,
  `heal: ${healed.events.map((e: any) => e.event).join(", ")}; ${healed.repaired} repaired`);
const rep = await call("repairs", { udid: simulator });
check(Array.isArray(rep.repairs) && typeof rep.learned === "object", `repairs: ${rep.repairs.length} for this simulator`);
const badHeal = await call("heal", { simulator, app, seconds: 0 }, true);
check(badHeal.result?.isError === true && JSON.parse(badHeal.result.content[0].text).error.code === "invalid_arguments",
  "heal with seconds 0: isError, code invalid_arguments");

const off = await call("off", { simulator });
check(off.alreadyStock === false && off.reenabled.length === slim.disabled.length, `off: re-enabled ${off.reenabled.length}`);

const doctor = await call("doctor", {});
check(doctor.checks.length >= 5, `doctor: ${doctor.checks.map((c: any) => `${c.id}=${c.status}`).join(", ")}`);

const run = await call("run", { app, simulator, grant: ["contacts", "calendar"] });
check(run.udid === simulator && run.launched === true && run.simulatorSource === "given",
  `run: installed and launched ${run.bundleIdentifier} (pid ${run.pid}) in ${run.seconds.total} s`);
check(JSON.stringify(run.granted) === JSON.stringify(["contacts", "calendar"]), `run: granted ${JSON.stringify(run.granted)}`);
check(typeof run.cloned === "boolean" && "replaced" in run, `run: cloned ${run.cloned}, replaced ${JSON.stringify(run.replaced)}`);

// shot in a custom set: screenshot, no tree; --grant all expands; --max-width shrinks.
const shot = await call("shot", { app, udid: simulator, noTree: true, maxWidth: 300, wait: "2", grant: ["all"] });
check(shot.screenshotWidth === 300 && shot.screenshotBytes > 0 && shot.treeStatus === "skipped",
  `shot: ${shot.screenshotWidth} px, ${shot.screenshotBytes} bytes, tree ${shot.treeStatus}`);
check(shot.granted.includes("photos") && !shot.granted.includes("all"), `shot: all expanded to ${shot.granted.length} grants`);
const badGrant = await call("shot", { app, udid: simulator, grant: ["notifications"] }, true);
check(badGrant.result?.isError === true && JSON.parse(badGrant.result.content[0].text).error.code === "invalid_arguments",
  "shot with grant notifications: isError, code invalid_arguments");

// Leases. A forced refusal first (boots nothing), then one real lease of a
// new fast-ios-lease-* simulator in the same set, released with shutdown.
// The test simulator is shut down first so only one simulator runs at a time.
await spawn(["xcrun", "simctl", "--set", deviceSet, "shutdown", simulator], { stdout: "ignore", stderr: "ignore" }).exited;
const empty = await call("leases", {});
check(Array.isArray(empty.leases) && typeof empty.memory?.availableMB === "number",
  `leases: ${empty.leases.length} lease(s), ${empty.memory.availableMB} MB available, pressure ${empty.memory.pressure}`);
const refused = await call("lease", { full: true, pid: process.pid, reserveMb: 999999, timeout: "2s" });
check(refused.status === "refused" && refused.reason === "memory" && refused.udid === null && refused.waitedSeconds >= 2,
  `lease under a forced low-memory threshold: refused, reason memory, after ${refused.waitedSeconds} s`);
const leased = await call("lease", { full: true, pid: process.pid, owner: "mcp-client", ttl: "10m",
  maxPressure: "warning", needMb: 900, reserveMb: 1000, timeout: "3m" });
check(leased.status === "leased" && typeof leased.udid === "string" && leased.udid !== simulator,
  `lease: ${leased.status} ${leased.udid} (${leased.source}, ${leased.prepareSeconds} s)`);
check("cloned" in leased && "replaced" in leased, `lease: cloned ${JSON.stringify(leased.cloned)}, replaced ${JSON.stringify(leased.replaced)}`);
const held = await call("leases", {});
check(held.leases.some((l: any) => l.udid === leased.udid && l.owner === "mcp-client" && l.ownerAlive === true),
  "leases lists the new lease with its owner alive");
const released = await call("release", { udid: leased.udid, shutdown: true });
check(released.status === "released", `release: ${released.status}`);
const again = await call("release", { udid: leased.udid });
check(again.status === "not-leased", "release twice: not-leased");

// Error paths.
const unknown = await call("no_such_tool", {}, true);
check(unknown.error?.code === -32602, "unknown tool: JSON-RPC error -32602");
const bad = await call("slim", { boot: "yes" }, true);
check(bad.result?.isError === true && JSON.parse(bad.result.content[0].text).error.code === "invalid_arguments",
  "slim with a missing simulator and a non-boolean boot: isError, code invalid_arguments");
const missing = await call("profile", { app: "/nonexistent/Nope.app" }, true);
check(missing.result?.isError === true && JSON.parse(missing.result.content[0].text).error.code === "app",
  "profile of a missing app: isError, code app");
const nomethod = await request("resources/list");
check(nomethod.error?.code === -32601, "unknown method: JSON-RPC error -32601");

proc.stdin.end();
await proc.exited;
console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`} (server exit ${proc.exitCode})`);
process.exit(failures === 0 ? 0 : 1);
