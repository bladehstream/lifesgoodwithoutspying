'use strict';

const childProcess = require('child_process');
const dgram = require('dgram');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

const bundle = path.join(__dirname, '..', 'dist', 'nospy-dns-filter.js');
// NOSPY_DNS_NODE runs the bundle under another Node, such as the 0.12 on webOS 3.x.
const runtime = process.env.NOSPY_DNS_NODE || process.execPath;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'nospy-forward-'));
const artifact = path.join(directory, 'domains.txt');
const statusFile = path.join(directory, 'status');
fs.writeFileSync(
  artifact,
  '# lifesgoodwithoutspying dns-filter generation smoke rules 1\nblocked.example.test\n',
);

let child = null;
let upstreamUdp = null;
let upstreamTcp = null;
let finished = false;
let upstreamQueryCount = 0;

function cleanup() {
  if (finished) {
    return;
  }
  finished = true;
  if (child !== null) {
    child.kill('SIGKILL');
  }
  if (upstreamUdp !== null) {
    upstreamUdp.close();
  }
  if (upstreamTcp !== null) {
    upstreamTcp.close();
  }
  try { fs.unlinkSync(artifact); } catch (_error) { /* best effort */ }
  try { fs.unlinkSync(statusFile); } catch (_error) { /* best effort */ }
  try { fs.rmdirSync(directory); } catch (_error) { /* best effort */ }
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function statusReady() {
  try {
    return fs.readFileSync(statusFile, 'utf8').split(/\n/).indexOf('ready=1') !== -1;
  } catch (_error) {
    return false;
  }
}

async function waitForReady() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (statusReady()) {
      return;
    }
    await sleep(100);
  }
  throw new Error('timed out waiting for the helper to listen');
}

// A port that was free a moment ago, for options that need a fixed number.
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

function makeQuery(id, name) {
  const labels = name.split('.').map((label) => {
    return Buffer.concat([Buffer.from([label.length]), Buffer.from(label, 'ascii')]);
  });
  const header = Buffer.alloc(12);
  header.writeUInt16BE(id, 0);
  header.writeUInt16BE(0x0100, 2);
  header.writeUInt16BE(1, 4);
  return Buffer.concat([header].concat(labels, [Buffer.from([0, 0, 1, 0, 1])]));
}

// The fake upstream echoes the question back as an empty NOERROR answer.
function makeAnswer(query) {
  const answer = Buffer.from(query);
  answer.writeUInt16BE(0x8180, 2);
  return answer;
}

function frame(message) {
  const length = Buffer.alloc(2);
  length.writeUInt16BE(message.length, 0);
  return Buffer.concat([length, message]);
}

function startUpstream() {
  return new Promise((resolve, reject) => {
    upstreamUdp = dgram.createSocket('udp4');
    upstreamUdp.on('message', (message, remote) => {
      upstreamQueryCount += 1;
      const answer = makeAnswer(message);
      upstreamUdp.send(answer, 0, answer.length, remote.port, remote.address);
    });
    upstreamUdp.once('error', reject);
    upstreamUdp.bind(0, '127.0.0.1', () => {
      const port = upstreamUdp.address().port;
      upstreamTcp = net.createServer((socket) => {
        let buffer = Buffer.alloc(0);
        socket.on('data', (chunk) => {
          buffer = Buffer.concat([buffer, chunk]);
          if (buffer.length >= 2 && buffer.length >= buffer.readUInt16BE(0) + 2) {
            upstreamQueryCount += 1;
            socket.end(frame(makeAnswer(buffer.slice(2, buffer.readUInt16BE(0) + 2))));
          }
        });
      });
      upstreamTcp.once('error', reject);
      upstreamTcp.listen(port, '127.0.0.1', () => resolve(port));
    });
  });
}

function queryUdp(port, query) {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket('udp4');
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('UDP query timed out'));
    }, 3000);
    socket.on('message', (message) => {
      clearTimeout(timer);
      socket.close();
      resolve(message);
    });
    socket.send(query, 0, query.length, port, '127.0.0.1');
  });
}

function queryTcp(port, query) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    let buffer = Buffer.alloc(0);
    socket.setTimeout(3000, () => {
      socket.destroy();
      reject(new Error('TCP query timed out'));
    });
    socket.on('error', reject);
    socket.on('connect', () => socket.write(frame(query)));
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length >= 2 && buffer.length >= buffer.readUInt16BE(0) + 2) {
        socket.destroy();
        resolve(buffer.slice(2, buffer.readUInt16BE(0) + 2));
      }
    });
  });
}

function expectAnswer(response, id, rcode, description) {
  if (response.readUInt16BE(0) !== id) {
    throw new Error(description + ': response ID mismatch');
  }
  if ((response.readUInt16BE(2) & 0x8000) === 0 || (response.readUInt16BE(2) & 0x000f) !== rcode) {
    throw new Error(description + ': expected rcode ' + rcode + ', got flags ' + response.readUInt16BE(2));
  }
}

(async function run() {
  const upstreamPort = await startUpstream();
  const listenPort = await freePort();
  // A one-port source range makes the helper pass localPort to every
  // upstream TCP connection.
  const sourcePort = await freePort();
  child = childProcess.spawn(runtime, [
    bundle,
    '--listen-address', '127.0.0.1',
    '--listen-port', String(listenPort),
    '--upstream', '127.0.0.1:' + upstreamPort,
    '--upstream-tcp-port-start', String(sourcePort),
    '--upstream-tcp-port-end', String(sourcePort),
    '--blocklist', artifact,
    '--status-file', statusFile,
  ], { stdio: ['ignore', 'ignore', 'inherit'] });
  await waitForReady();

  expectAnswer(await queryUdp(listenPort, makeQuery(0x1111, 'blocked.example.test')), 0x1111, 3, 'blocked UDP');
  expectAnswer(await queryUdp(listenPort, makeQuery(0x2222, 'allowed.example.test')), 0x2222, 0, 'forwarded UDP');
  expectAnswer(await queryTcp(listenPort, makeQuery(0x3333, 'blocked.example.test')), 0x3333, 3, 'blocked TCP');
  expectAnswer(await queryTcp(listenPort, makeQuery(0x4444, 'allowed.example.test')), 0x4444, 0, 'forwarded TCP');

  const beforeMulti = upstreamQueryCount;
  for (const firstBlocked of [false, true]) {
    const first = firstBlocked ? 'blocked.example.test' : 'allowed.example.test';
    const second = firstBlocked ? 'allowed.example.test' : 'blocked.example.test';
    const request = Buffer.concat([makeQuery(0x5555, first), makeQuery(0, second).slice(12)]);
    request.writeUInt16BE(2, 4);
    for (const send of [queryUdp, queryTcp]) {
      const response = await send(listenPort, request);
      expectAnswer(response, 0x5555, 1, 'multi-question FORMERR');
      if (response.length !== 12 || response.readUInt16BE(4) !== 0 ||
          response.readUInt16BE(6) !== 0 || response.readUInt16BE(8) !== 0 ||
          response.readUInt16BE(10) !== 0) {
        throw new Error('multi-question FORMERR must contain only an empty header');
      }
    }
  }
  await sleep(50);
  if (upstreamQueryCount !== beforeMulti) {
    throw new Error('multi-question request reached upstream');
  }

  console.log('forwarding smoke passed');
  cleanup();
})().catch((error) => {
  console.error(error.stack || error);
  cleanup();
  process.exitCode = 1;
});
