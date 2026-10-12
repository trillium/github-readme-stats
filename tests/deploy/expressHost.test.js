/**
 * @jest-environment node
 */
import { spawn } from "child_process";
import net from "net";
import os from "os";
import { afterAll, beforeAll, describe, expect, it } from "@jest/globals";

const PORT = 39000 + Math.floor(Math.random() * 1000);
let child;

const canConnect = (host) =>
  new Promise((resolve) => {
    const socket = net.connect({ host, port: PORT, timeout: 500 });
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
    socket.once("timeout", () => {
      socket.destroy();
      resolve(false);
    });
  });

beforeAll(async () => {
  child = spawn("node", ["express.js"], {
    env: { ...process.env, port: String(PORT), host: "127.0.0.1" },
    stdio: "ignore",
  });
  for (let i = 0; i < 50 && !(await canConnect("127.0.0.1")); i++) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
});

afterAll(() => child.kill());

describe("express.js renderer as run by stats-cache-renderer.service", () => {
  it("answers on loopback and 404s unknown routes", async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/no-such-card`);
    expect(res.status).toBe(404);
  });

  it("is not reachable on the machine's other addresses when host=127.0.0.1", async () => {
    const external = Object.values(os.networkInterfaces())
      .flat()
      .filter((a) => a.family === "IPv4" && !a.internal)
      .map((a) => a.address);
    for (const address of external) {
      expect(await canConnect(address)).toBe(false);
    }
  });
});
