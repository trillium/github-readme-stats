/**
 * @jest-environment node
 */
import { execFile } from "child_process";
import fs from "fs";
import http from "http";
import os from "os";
import path from "path";
import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "@jest/globals";
import { renderError } from "../../src/common/utils.js";

const DEPLOY = path.resolve("deploy/vps01-cache");
const SCRIPT = path.join(DEPLOY, "bin/stats-cache-refresh");

const GOOD_CARD = `<svg width="495" height="195"><text data-testid="card-title">Trillium's GitHub Stats</text></svg>`;
const OLD_CARD = `<svg width="495" height="195"><text data-testid="card-title">old copy</text></svg>`;

let server;
let base;
let tmp;
let reply;
let requests;

const run = (env = {}) =>
  new Promise((resolve) => {
    execFile(
      SCRIPT,
      [],
      {
        env: {
          ...process.env,
          CARDS_FILE: path.join(tmp, "cards.conf"),
          CACHE_DIR: path.join(tmp, "www"),
          STATE_DIR: path.join(tmp, "state"),
          UPSTREAM_BASE: base,
          FRESH_SECONDS: "3600",
          MIN_RETRY_SECONDS: "120",
          FETCH_TIMEOUT: "1",
          ...env,
        },
      },
      (error, stdout, stderr) =>
        resolve({ code: error ? error.code : 0, stdout, stderr }),
    );
  });

const cached = (name) => path.join(tmp, "www", `${name}.svg`);
const ago = (file, seconds) => {
  const t = new Date(Date.now() - seconds * 1000);
  fs.utimesSync(file, t, t);
};
const stale = (name) => {
  fs.writeFileSync(cached(name), OLD_CARD);
  ago(cached(name), 7200);
};
const clearAttempts = () =>
  fs.rmSync(path.join(tmp, "state"), { recursive: true, force: true });

beforeAll(async () => {
  server = http.createServer((req, res) => {
    requests.push(req.url);
    if (reply.hang) {
      return; // never answer, to trigger the client timeout
    }
    res.writeHead(reply.status, { "Content-Type": "image/svg+xml" });
    res.end(reply.body);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

afterAll(() => {
  server.closeAllConnections();
  server.close();
});

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "stats-cache-"));
  fs.copyFileSync(
    path.join(DEPLOY, "cards.conf"),
    path.join(tmp, "cards.conf"),
  );
  fs.mkdirSync(path.join(tmp, "www"));
  reply = { status: 200, body: GOOD_CARD };
  requests = [];
});

describe("stats-cache-refresh", () => {
  it("writes both allowlisted cards from the upstream", async () => {
    const { code } = await run();
    expect(code).toBe(0);
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(GOOD_CARD);
    expect(fs.readFileSync(cached("top-langs"), "utf8")).toBe(GOOD_CARD);
    expect(requests).toHaveLength(2);
    expect(requests.every((url) => url.includes("username=trillium"))).toBe(
      true,
    );
    expect(requests[0].startsWith("/?")).toBe(true);
    expect(requests[1].startsWith("/top-langs?")).toBe(true);
  });

  it("fetches exactly the cards in the allowlist and writes nothing else", async () => {
    fs.writeFileSync(
      path.join(tmp, "cards.conf"),
      "# comment\n\n  # indented comment\nonly /api/?username=trillium&x=1\n",
    );
    const { code } = await run();
    expect(code).toBe(0);
    expect(requests).toEqual(["/api/?username=trillium&x=1"]);
    expect(fs.readdirSync(path.join(tmp, "www"))).toEqual(["only.svg"]);
  });

  it("does not contact the upstream while the copy is fresh", async () => {
    fs.writeFileSync(cached("stats"), OLD_CARD);
    fs.writeFileSync(cached("top-langs"), OLD_CARD);
    await run();
    expect(requests).toHaveLength(0);
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(OLD_CARD);
  });

  it("refreshes only the stale copy", async () => {
    stale("stats");
    fs.writeFileSync(cached("top-langs"), OLD_CARD);
    await run();
    expect(requests).toHaveLength(1);
    expect(requests[0].startsWith("/?")).toBe(true);
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(GOOD_CARD);
    expect(fs.readFileSync(cached("top-langs"), "utf8")).toBe(OLD_CARD);
  });

  it("keeps the last good copy when the upstream answers non-200", async () => {
    stale("stats");
    reply = { status: 500, body: GOOD_CARD };
    const { code } = await run();
    expect(code).toBe(1);
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(OLD_CARD);
  });

  it("keeps the last good copy when the upstream times out", async () => {
    stale("stats");
    reply = { hang: true };
    const { code } = await run();
    expect(code).toBe(1);
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(OLD_CARD);
  });

  it("keeps the last good copy when the upstream returns an error card with status 200", async () => {
    stale("stats");
    reply = {
      status: 200,
      body: renderError(
        "Could not fetch user",
        "Make sure the username is right",
      ),
    };
    const { code, stderr } = await run();
    expect(code).toBe(1);
    expect(stderr).toContain("error card");
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(OLD_CARD);
  });

  it("rejects empty and non-svg bodies", async () => {
    for (const body of ["", "<html>captive portal</html>"]) {
      clearAttempts();
      reply = { status: 200, body };
      const { code } = await run();
      expect(code).toBe(1);
      expect(fs.existsSync(cached("stats"))).toBe(false);
    }
  });

  it("leaves no temp files behind after a failure", async () => {
    reply = { status: 502, body: "bad gateway" };
    await run();
    expect(fs.readdirSync(path.join(tmp, "www"))).toEqual([]);
  });

  it("retries a failing upstream at most once per MIN_RETRY_SECONDS", async () => {
    stale("stats");
    fs.writeFileSync(cached("top-langs"), OLD_CARD);
    reply = { status: 500, body: "" };
    await run();
    await run();
    await run();
    expect(requests).toHaveLength(1);
    reply = { status: 200, body: GOOD_CARD };
    ago(path.join(tmp, "state", "stats.attempt"), 7200);
    await run();
    expect(requests).toHaveLength(2);
    expect(fs.readFileSync(cached("stats"), "utf8")).toBe(GOOD_CARD);
  });
});
