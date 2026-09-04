const apiKey = process.env.E2B_API_KEY;
const apiUrl = process.env.E2B_API_URL || "http://127.0.0.1:8080";
const domain = process.env.E2B_DOMAIN;
const template = process.env.DOCTOR_E2B_TEMPLATE || "kodus-sandbox";
const publicIp = process.env.DOCTOR_HOST_PUBLIC_IP || "";
const lanIp = process.env.DOCTOR_LAN_IP || "";
const orchPort = process.env.DOCTOR_ORCHESTRATOR_PORT || "5008";
const npmUrl = process.env.DOCTOR_NPM_URL || "https://registry.npmjs.org";
const hostListener = process.env.ISOLATION_HOST_LISTENER || "unproven";
const lanListener = process.env.ISOLATION_LAN_LISTENER || "unproven";

function fail(stage, error, isolation) {
  const iso = isolation || {
    ok: false,
    targets_valid: false,
    host_health: "inconclusive",
    npm: "inconclusive",
    lan: "inconclusive",
    host_listener: hostListener,
    lan_listener: lanListener,
  };
  console.log(JSON.stringify({ ok: false, echo: "fail", isolation: iso, killed: false, stage, error }));
  process.exit(1);
}

if (!apiKey) {
  fail("config", "E2B_API_KEY is empty");
}

const e2bPath = process.env.DOCTOR_E2B_SDK || "e2b";
const { Sandbox } = await import(e2bPath);

let sandbox;
try {
  sandbox = await Sandbox.create(template, { apiKey, apiUrl, domain });
} catch (err) {
  fail("create", String(err));
}

let echoOut = "";
try {
  const result = await sandbox.commands.run("echo ok");
  echoOut = (result.stdout || "") + (result.stderr || "");
} catch (err) {
  try { await sandbox.kill(); } catch { /* ignore */ }
  fail("echo", String(err));
}

const probe = `
set +e
host=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 --noproxy '*' http://${publicIp}:${orchPort}/health); host_rc=$?
npm=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 --noproxy '*' -L ${npmUrl}); npm_rc=$?
lan=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 --noproxy '*' http://${lanIp}/); lan_rc=$?
echo HOST:$host:$host_rc NPM:$npm:$npm_rc LAN:$lan:$lan_rc
`;

let probeOut = "";
try {
  const result = await sandbox.commands.run(probe);
  probeOut = (result.stdout || "") + (result.stderr || "");
} catch (err) {
  probeOut = `PROBE_ERROR ${err}`;
}

let killed = false;
try {
  await sandbox.kill();
  killed = true;
} catch {
  killed = false;
}

function classifyDeny(code, rc, listener) {
  const n = Number(rc);
  if (n === 7 || n === 28) return listener === "live" ? "blocked" : "inconclusive";
  if (n === 6) return "inconclusive";
  if (n === 0 && /^[1234]/.test(code)) return "reachable";
  return "inconclusive";
}
function classifyAllow(code, rc) {
  const n = Number(rc);
  if (n === 0 && /^[23]/.test(code)) return "ok";
  if (n === 127 || Number.isNaN(n)) return "inconclusive";
  return "fail";
}

const match = probeOut.match(/HOST:(\d+|):(\-?\d+)\s+NPM:(\d+|):(\-?\d+)\s+LAN:(\d+|):(\-?\d+)/);
let isolation;
if (!match) {
  isolation = {
    ok: false,
    targets_valid: false,
    host_health: "inconclusive",
    npm: "inconclusive",
    lan: "inconclusive",
    host_listener: hostListener,
    lan_listener: lanListener,
    raw: probeOut.slice(-400),
  };
} else {
  const host = classifyDeny(match[1], match[2], hostListener);
  const npm = classifyAllow(match[3], match[4]);
  const lan = classifyDeny(match[5], match[6], lanListener);
  isolation = {
    ok: host === "blocked" && npm === "ok" && lan === "blocked" && hostListener === "live" && lanListener === "live",
    targets_valid: true,
    host_health: host,
    npm,
    lan,
    host_listener: hostListener,
    lan_listener: lanListener,
    public_ip: publicIp,
    lan_ip: lanIp,
  };
}

const ok = echoOut.includes("ok") && isolation.ok === true && killed
  && isolation.host_health === "blocked" && isolation.npm === "ok" && isolation.lan === "blocked"
  && isolation.host_listener === "live" && isolation.lan_listener === "live";
console.log(JSON.stringify({ ok, echo: echoOut.includes("ok") ? "ok" : echoOut.trim().slice(0, 80), isolation, killed }));
process.exit(ok ? 0 : 1);
