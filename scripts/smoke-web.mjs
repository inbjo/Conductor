#!/usr/bin/env node
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { spawn } from 'node:child_process';

const baseUrl = process.env.CONDUCTOR_SMOKE_BASE_URL || process.argv[2] || 'http://127.0.0.1:18080';
const username = process.env.CONDUCTOR_SMOKE_ADMIN_USERNAME || 'admin';
const password = process.env.CONDUCTOR_SMOKE_ADMIN_PASSWORD || 'admin123';
const hostname = process.env.CONDUCTOR_SMOKE_AGENT_NAME || 'demo-smoke-agent';
const chromeBin = process.env.CHROME_BIN || process.env.CHROMIUM_BIN || 'chromium-browser';

let browser;
let userDataDir;

function assert(value, message) {
  if (!value) throw new Error(message);
}

async function waitFor(fn, label, timeoutMs = 10000) {
  const started = Date.now();
  let lastError;
  while (Date.now() - started < timeoutMs) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await delay(150);
  }
  throw new Error(`${label} timed out${lastError ? `: ${lastError.message}` : ''}`);
}

class CdpClient {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    socket.addEventListener('message', async (event) => {
      const text = await messageText(event.data);
      const payload = JSON.parse(text);
      if (!payload.id) return;
      const request = this.pending.get(payload.id);
      if (!request) return;
      this.pending.delete(payload.id);
      clearTimeout(request.timer);
      if (payload.error) request.reject(new Error(payload.error.message));
      else request.resolve(payload.result || {});
    });
  }

  send(method, params = {}, sessionId) {
    const id = this.nextId++;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    this.socket.send(JSON.stringify(payload));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} timed out`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timer });
    });
  }
}

async function messageText(data) {
  if (typeof data === 'string') return data;
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString('utf8');
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('utf8');
  if (data && typeof data.text === 'function') return data.text();
  return String(data);
}

async function launchBrowser() {
  userDataDir = await mkdtemp(join(tmpdir(), 'conductor-web-smoke-'));
  browser = spawn(chromeBin, [
    '--headless=new',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--no-first-run',
    '--no-default-browser-check',
    '--no-sandbox',
    '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`,
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  let stderr = '';
  browser.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  browser.on('exit', (code) => {
    if (code !== null && code !== 0) {
      console.error(stderr.trim());
    }
  });

  const activePort = join(userDataDir, 'DevToolsActivePort');
  const content = await waitFor(async () => {
    try {
      return await readFile(activePort, 'utf8');
    } catch {
      if (browser.exitCode !== null) throw new Error(`chromium exited: ${stderr.trim()}`);
      return '';
    }
  }, 'chromium devtools port');
  const [port] = content.trim().split('\n');
  const targets = await waitFor(async () => {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`);
    const pages = await response.json();
    return pages.find((target) => target.type === 'page' && target.webSocketDebuggerUrl);
  }, 'chromium page target');
  const socket = new WebSocket(targets.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  const client = new CdpClient(socket);
  await client.send('Page.enable');
  await client.send('Runtime.enable');
  return { client };
}

async function evalInPage(client, expression) {
  const result = await client.send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || 'page evaluation failed');
  }
  return result.result?.value;
}

async function navigate(client, path) {
  await client.send('Page.navigate', { url: new URL(path, baseUrl).toString() });
  await waitFor(() => evalInPage(client, 'document.readyState === "complete"'), `load ${path}`);
}

async function bodyIncludes(client, text) {
  return evalInPage(client, `document.body?.innerText.includes(${JSON.stringify(text)})`);
}

async function main() {
  const { client } = await launchBrowser();

  await navigate(client, '/login');
  assert(await bodyIncludes(client, '管理员登录'), 'login page did not render');
  await evalInPage(client, `
    (() => {
      const setInput = (selector, value) => {
        const input = document.querySelector(selector);
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(input, value);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      };
      setInput('input[autocomplete="username"]', ${JSON.stringify(username)});
      setInput('input[autocomplete="current-password"]', ${JSON.stringify(password)});
      document.querySelector('button.primary').click();
      return true;
    })()
  `);
  await waitFor(() => evalInPage(client, 'location.pathname === "/devices"'), 'login redirect');
  await waitFor(() => bodyIncludes(client, '终端资产'), 'devices page');
  await waitFor(() => bodyIncludes(client, hostname), 'registered agent row');

  const deviceId = await evalInPage(client, `
    (async () => {
      const token = localStorage.getItem('conductor.token');
      const response = await fetch('/api/devices', { headers: { Authorization: 'Bearer ' + token } });
      const devices = await response.json();
      const device = devices.find((item) => item.hostname === ${JSON.stringify(hostname)});
      return device && device.device_id;
    })()
  `);
  assert(deviceId, `device id not found for ${hostname}`);
  await evalInPage(client, `
    (async () => {
      const token = localStorage.getItem('conductor.token');
      const response = await fetch('/api/sessions?device_id=${deviceId}&limit=20', {
        headers: { Authorization: 'Bearer ' + token },
      });
      const sessions = await response.json();
      await Promise.all(
        sessions
          .filter((session) => ['pending', 'active'].includes(session.status))
          .map((session) => fetch('/api/sessions/' + session.session_id + '/close', {
            method: 'POST',
            headers: { Authorization: 'Bearer ' + token },
          })),
      );
      return true;
    })()
  `);

  await evalInPage(client, `
    (() => {
      const row = [...document.querySelectorAll('tr')].find((item) => item.innerText.includes(${JSON.stringify(hostname)}));
      row.click();
      return true;
    })()
  `);
  await waitFor(() => evalInPage(client, `location.pathname === '/devices/${deviceId}'`), 'device detail route');
  await waitFor(() => bodyIncludes(client, '远程控制'), 'device detail actions');

  const remoteSessionId = await evalInPage(client, `
    (async () => {
      const token = localStorage.getItem('conductor.token');
      const response = await fetch('/api/sessions', {
        method: 'POST',
        headers: {
          Authorization: 'Bearer ' + token,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ device_id: ${JSON.stringify(deviceId)} }),
      });
      const session = await response.json();
      return session.session_id;
    })()
  `);
  assert(remoteSessionId, 'remote session was not created');
  await waitFor(() => evalInPage(client, `
    (async () => {
      const token = localStorage.getItem('conductor.token');
      const response = await fetch('/api/sessions/${remoteSessionId}', {
        headers: { Authorization: 'Bearer ' + token },
      });
      const session = await response.json();
      return session.status === 'active';
    })()
  `), 'active session', 12000);

  await navigate(client, `/devices/${deviceId}/files`);
  await waitFor(() => bodyIncludes(client, '远端文件'), 'files page');
  await waitFor(() => bodyIncludes(client, '刷新'), 'files toolbar');
  await evalInPage(client, `
    (async () => {
      const token = localStorage.getItem('conductor.token');
      await fetch('/api/sessions/${remoteSessionId}/close', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + token },
      });
      return true;
    })()
  `);

  console.log(`Web smoke test passed for ${baseUrl}`);
}

try {
  await main();
} finally {
  if (browser && browser.exitCode === null) {
    browser.kill();
    await new Promise((resolve) => browser.once('exit', resolve));
  }
  if (userDataDir) await rm(userDataDir, { recursive: true, force: true });
}
