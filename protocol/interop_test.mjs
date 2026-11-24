#!/usr/bin/env node
/**
 * Cross-platform DLSP/1 interoperability test suite.
 * Spawns the compiled Swift macOS DropLink server harness and connects to it
 * using an independent Node.js DLSP/1 implementation over real TCP sockets.
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const swiftHarness = [
  path.join(rootDir, 'macos/.build/release-manual/DropLinkTests'),
  path.join(rootDir, 'macos/.build/manual/DropLinkTests'),
].find((p) => fs.existsSync(p)) || path.join(rootDir, 'macos/.build/release-manual/DropLinkTests');

function sha256Buf(buf) {
  return crypto.createHash('sha256').update(buf).digest();
}
function hmacSha256(key, str) {
  return crypto.createHmac('sha256', key).update(str, 'utf8').digest();
}
function hkdf32(ikm, salt, info) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), 32));
}

class FramedSocket {
  constructor(sock) {
    this.sock = sock;
    this.buf = Buffer.alloc(0);
    this.waiters = [];
    this.closed = false;
    sock.on('data', (chunk) => {
      this.buf = Buffer.concat([this.buf, chunk]);
      this._drain();
    });
    sock.on('close', () => {
      this.closed = true;
      for (const w of this.waiters) w.reject(new Error('Socket closed'));
      this.waiters = [];
    });
    sock.on('error', (err) => {
      this.closed = true;
      for (const w of this.waiters) w.reject(err);
      this.waiters = [];
    });
  }

  _drain() {
    while (this.waiters.length > 0 && this.buf.length >= this.waiters[0].n) {
      const { n, resolve } = this.waiters.shift();
      const out = this.buf.subarray(0, n);
      this.buf = this.buf.subarray(n);
      resolve(out);
    }
  }

  readExact(n) {
    if (this.buf.length >= n) {
      const out = this.buf.subarray(0, n);
      this.buf = this.buf.subarray(n);
      return Promise.resolve(out);
    }
    if (this.closed) return Promise.reject(new Error('Socket closed'));
    return new Promise((resolve, reject) => {
      this.waiters.push({ n, resolve, reject });
    });
  }

  async readFrame() {
    const lenBuf = await this.readExact(4);
    const len = lenBuf.readUInt32BE(0);
    return this.readExact(len);
  }

  writeFrame(payload) {
    const hdr = Buffer.alloc(4);
    hdr.writeUInt32BE(payload.length, 0);
    return new Promise((resolve, reject) => {
      this.sock.write(Buffer.concat([hdr, payload]), (err) => (err ? reject(err) : resolve()));
    });
  }

  close() {
    this.sock.destroy();
  }
}

class NodeDLSPClient {
  constructor(fsock, keys) {
    this.fsock = fsock;
    this.c2sKey = keys.c2sKey;
    this.s2cKey = keys.s2cKey;
    this.sendSeq = 0n;
    this.recvSeq = 0n;
  }

  async sendEncrypted(frameType, payloadBuf) {
    const plaintext = Buffer.concat([Buffer.from([frameType]), payloadBuf]);
    const nonce = Buffer.alloc(12);
    nonce.writeUInt32BE(1, 0);
    nonce.writeBigUInt64BE(this.sendSeq, 4);

    const aad = Buffer.alloc(16);
    aad.writeUInt32BE(1, 0);
    aad.writeBigUInt64BE(this.sendSeq, 4);
    aad.writeUInt32BE(plaintext.length, 12);
    this.sendSeq += 1n;

    const cipher = crypto.createCipheriv('aes-256-gcm', this.c2sKey, nonce);
    cipher.setAAD(aad);
    const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const tag = cipher.getAuthTag();
    await this.fsock.writeFrame(Buffer.concat([ct, tag]));
  }

  async recvEncrypted() {
    const body = await this.fsock.readFrame();
    const ct = body.subarray(0, body.length - 16);
    const tag = body.subarray(body.length - 16);

    const nonce = Buffer.alloc(12);
    nonce.writeUInt32BE(2, 0);
    nonce.writeBigUInt64BE(this.recvSeq, 4);

    const aad = Buffer.alloc(16);
    aad.writeUInt32BE(2, 0);
    aad.writeBigUInt64BE(this.recvSeq, 4);
    aad.writeUInt32BE(ct.length, 12);
    this.recvSeq += 1n;

    const decipher = crypto.createDecipheriv('aes-256-gcm', this.s2cKey, nonce);
    decipher.setAAD(aad);
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(ct), decipher.final()]);
    return { type: plaintext[0], payload: plaintext.subarray(1) };
  }
}

async function connectHandshake({ port, sessionId, authKey, mode = 'pair', reconnectToken = null, deviceId = 'node-android-sim', deviceName = 'Node Android Sim' }) {
  const sock = await new Promise((resolve, reject) => {
    const s = net.createConnection({ host: '127.0.0.1', port }, () => resolve(s));
    s.on('error', reject);
  });
  const fsock = new FramedSocket(sock);

  const ecdh = crypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const clientPubHex = ecdh.getPublicKey().toString('hex');
  const clientNonce = crypto.randomBytes(32).toString('hex');
  const authProof = hmacSha256(authKey, `DLSP1-CLIENT|${sessionId}|${mode}|${clientNonce}|${clientPubHex}|${deviceId}`).toString('hex');

  const hello = {
    protocol: 'DLSP/1',
    sessionId,
    mode,
    reconnectToken,
    deviceId,
    deviceName,
    clientNonce,
    clientPublicKey: clientPubHex,
    authProof,
  };
  await fsock.writeFrame(Buffer.from(JSON.stringify(hello), 'utf8'));
  const replyBuf = await fsock.readFrame();
  const reply = JSON.parse(replyBuf.toString('utf8'));
  if (!reply.ok) {
    fsock.close();
    return { ok: false, reply };
  }

  const expectedServerProof = hmacSha256(
    authKey,
    `DLSP1-SERVER|${sessionId}|${mode}|${clientNonce}|${reply.serverNonce}|${clientPubHex}|${reply.serverPublicKey}`
  ).toString('hex');
  assert.equal(reply.serverProof, expectedServerProof, 'Server proof verification failed');

  const shared = ecdh.computeSecret(Buffer.from(reply.serverPublicKey, 'hex'));
  const ikm = Buffer.concat([shared, authKey]);
  const salt = sha256Buf(Buffer.from(`DLSP1-SALT|${sessionId}|${clientNonce}|${reply.serverNonce}`, 'utf8'));
  const keys = {
    c2sKey: hkdf32(ikm, salt, 'DLSP1-C2S-KEY'),
    s2cKey: hkdf32(ikm, salt, 'DLSP1-S2C-KEY'),
    reconnectKey: hkdf32(ikm, salt, 'DLSP1-RECONNECT'),
  };

  return {
    ok: true,
    client: new NodeDLSPClient(fsock, keys),
    reconnectToken: reply.reconnectToken,
    reconnectKey: keys.reconnectKey,
    serverName: reply.serverName,
  };
}

function uuidToBytes(uuidStr) {
  return Buffer.from(uuidStr.replace(/-/g, ''), 'hex');
}

async function run() {
  console.log('=== Cross-Platform DLSP/1 Interoperability Tests (Node.js <-> Compiled Swift macOS Server) ===');
  if (!fs.existsSync(swiftHarness)) {
    throw new Error(`Compiled Swift harness missing at ${swiftHarness}`);
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'droplink-interop-'));
  const macDest = path.join(tmpDir, 'mac_rx');
  fs.mkdirSync(macDest, { recursive: true });

  const proc = spawn(swiftHarness, ['--serve-harness', '--dir', macDest], { stdio: ['pipe', 'pipe', 'pipe'] });
  let readyInfo = null;
  let stdoutBuf = '';
  const readyPromise = new Promise((resolve, reject) => {
    proc.stdout.on('data', (d) => {
      stdoutBuf += d.toString('utf8');
      for (const line of stdoutBuf.split('\n')) {
        if (line.startsWith('HARNESS_READY:')) {
          readyInfo = JSON.parse(line.slice('HARNESS_READY:'.length));
          resolve(readyInfo);
        }
      }
    });
    proc.on('exit', (code) => {
      if (!readyInfo) reject(new Error(`Swift harness exited early with code ${code}`));
    });
  });

  try {
    const info = await readyPromise;
    const psk = Buffer.from(info.pskHex, 'hex');

    // Test 1: QR URI parsing
    const parsedUrl = new URL(info.qrUri);
    assert.equal(parsedUrl.protocol, 'droplink:');
    assert.equal(parsedUrl.hostname, 'pair');
    assert.equal(Number(parsedUrl.searchParams.get('p')), info.port);
    assert.equal(parsedUrl.searchParams.get('s'), info.sessionId);
    assert.equal(Buffer.from(parsedUrl.searchParams.get('k'), 'base64url').toString('hex'), info.pskHex);
    console.log('  [PASS] 1. QR URI generated by Swift macOS parses cleanly in independent client');

    // Test 2: Wrong PSK rejected by Swift server
    const badRes = await connectHandshake({
      port: info.port,
      sessionId: info.sessionId,
      authKey: crypto.randomBytes(32),
    });
    assert.equal(badRes.ok, false);
    assert.equal(badRes.reply.code, 'AUTH_FAILED');
    console.log('  [PASS] 2. Swift server rejects forged/wrong PSK with AUTH_FAILED');

    // Test 3: Valid mutual-authenticated P-256 ECDH + PSK handshake + 10 MB Unicode upload
    const conn = await connectHandshake({
      port: info.port,
      sessionId: info.sessionId,
      authKey: psk,
    });
    assert.equal(conn.ok, true);
    assert.equal(conn.serverName, 'Swift Test Mac');

    const payload10MB = crypto.randomBytes(10 * 1024 * 1024);
    const sha10MB = sha256Buf(payload10MB).toString('hex');
    const tid1 = crypto.randomUUID();
    const fname1 = 'Cross-Platform テスト 🚀 (v2).bin';
    await conn.client.sendEncrypted(0x10, Buffer.from(JSON.stringify({
      transferId: tid1,
      filename: fname1,
      size: payload10MB.length,
      mimeType: 'application/octet-stream',
      chunkSize: 262144,
    })));
    const acc1 = await conn.client.recvEncrypted();
    assert.equal(acc1.type, 0x11);
    assert.equal(JSON.parse(acc1.payload.toString('utf8')).resumeOffset, 0);

    const tid1Bytes = uuidToBytes(tid1);
    for (let off = 0; off < payload10MB.length; off += 262144) {
      const slice = payload10MB.subarray(off, Math.min(off + 262144, payload10MB.length));
      const offBuf = Buffer.alloc(8);
      offBuf.writeBigUInt64BE(BigInt(off), 0);
      await conn.client.sendEncrypted(0x13, Buffer.concat([tid1Bytes, offBuf, slice]));
    }
    await conn.client.sendEncrypted(0x14, Buffer.from(JSON.stringify({
      transferId: tid1,
      sha256: sha10MB,
      totalBytes: payload10MB.length,
    })));
    const ack1 = await conn.client.recvEncrypted();
    assert.equal(ack1.type, 0x15);
    const ack1Json = JSON.parse(ack1.payload.toString('utf8'));
    assert.equal(ack1Json.verified, true);
    assert.equal(ack1Json.savedFilename, fname1);
    assert.equal(sha256Buf(fs.readFileSync(path.join(macDest, fname1))).toString('hex'), sha10MB);
    console.log('  [PASS] 3. Cross-platform 10 MB encrypted Unicode upload verified byte-for-byte on Mac');

    // Test 4: Corrupted SHA-256 rejected cleanly without leaving corrupt file
    const tidBad = crypto.randomUUID();
    const badName = 'corrupted-should-not-exist.dat';
    const badData = Buffer.from('hello corrupted world');
    await conn.client.sendEncrypted(0x10, Buffer.from(JSON.stringify({
      transferId: tidBad,
      filename: badName,
      size: badData.length,
      mimeType: 'application/octet-stream',
      chunkSize: 65536,
    })));
    const accBad = await conn.client.recvEncrypted();
    assert.equal(accBad.type, 0x11);
    const offZero = Buffer.alloc(8);
    await conn.client.sendEncrypted(0x13, Buffer.concat([uuidToBytes(tidBad), offZero, badData]));
    await conn.client.sendEncrypted(0x14, Buffer.from(JSON.stringify({
      transferId: tidBad,
      sha256: '0'.repeat(64),
      totalBytes: badData.length,
    })));
    const ackBad = await conn.client.recvEncrypted();
    assert.equal(ackBad.type, 0x15);
    assert.equal(JSON.parse(ackBad.payload.toString('utf8')).verified, false);
    assert.equal(fs.existsSync(path.join(macDest, badName)), false);
    console.log('  [PASS] 4. Corrupted SHA-256 transfer rejected cleanly (no corrupt file saved)');

    // Test 5: Mac -> Client streaming download
    const macOutFile = path.join(tmpDir, 'From Mac Interop 🎵.bin');
    const macOutData = crypto.randomBytes(3 * 1024 * 1024);
    const macOutSha = sha256Buf(macOutData).toString('hex');
    fs.writeFileSync(macOutFile, macOutData);

    proc.stdin.write(`SEND ${macOutFile}\n`);
    const offerMsg = await conn.client.recvEncrypted();
    assert.equal(offerMsg.type, 0x10);
    const offer = JSON.parse(offerMsg.payload.toString('utf8'));
    assert.equal(offer.filename, 'From Mac Interop 🎵.bin');
    assert.equal(offer.size, macOutData.length);
    await conn.client.sendEncrypted(0x11, Buffer.from(JSON.stringify({ transferId: offer.transferId, resumeOffset: 0 })));

    const rxChunks = [];
    let completeMsg = null;
    while (true) {
      const f = await conn.client.recvEncrypted();
      if (f.type === 0x13) {
        rxChunks.push(f.payload.subarray(24));
      } else if (f.type === 0x14) {
        completeMsg = JSON.parse(f.payload.toString('utf8'));
        break;
      }
    }
    const receivedBuf = Buffer.concat(rxChunks);
    const receivedSha = sha256Buf(receivedBuf).toString('hex');
    assert.equal(receivedSha, macOutSha);
    assert.equal(receivedSha, completeMsg.sha256);
    await conn.client.sendEncrypted(0x15, Buffer.from(JSON.stringify({
      transferId: offer.transferId,
      verified: true,
      savedFilename: offer.filename,
    })));
    console.log('  [PASS] 5. Cross-platform Mac -> Client 3 MB streaming download verified byte-for-byte');

    // Test 6: Real mid-transfer TCP interruption + QR expiry + Reconnect + Seamless Byte-Offset Resume!
    const resumeData = crypto.randomBytes(2 * 1024 * 1024);
    const resumeSha = sha256Buf(resumeData).toString('hex');
    const tidRes = crypto.randomUUID();
    const resName = 'interrupted-resumed.bin';
    await conn.client.sendEncrypted(0x10, Buffer.from(JSON.stringify({
      transferId: tidRes,
      filename: resName,
      size: resumeData.length,
      mimeType: 'application/octet-stream',
      chunkSize: 131072,
    })));
    const accRes1 = await conn.client.recvEncrypted();
    assert.equal(accRes1.type, 0x11);

    // Send only first 512 KiB then violently drop TCP connection!
    const splitPoint = 512 * 1024;
    for (let off = 0; off < splitPoint; off += 131072) {
      const slice = resumeData.subarray(off, off + 131072);
      const offBuf = Buffer.alloc(8);
      offBuf.writeBigUInt64BE(BigInt(off), 0);
      await conn.client.sendEncrypted(0x13, Buffer.concat([uuidToBytes(tidRes), offBuf, slice]));
    }
    await new Promise((r) => setTimeout(r, 150));
    conn.client.fsock.close();

    // Expire QR on Mac to confirm reconnectToken works after QR expiry
    proc.stdin.write('EXPIRE\n');
    await new Promise((r) => setTimeout(r, 150));

    // Reconnect with reconnectToken + reconnectKey
    const conn2 = await connectHandshake({
      port: info.port,
      sessionId: info.sessionId,
      authKey: conn.reconnectKey,
      mode: 'reconnect',
      reconnectToken: conn.reconnectToken,
    });
    assert.equal(conn2.ok, true);

    // Re-offer same transferId -> Mac must report resumeOffset == splitPoint!
    await conn2.client.sendEncrypted(0x10, Buffer.from(JSON.stringify({
      transferId: tidRes,
      filename: resName,
      size: resumeData.length,
      mimeType: 'application/octet-stream',
      chunkSize: 131072,
    })));
    const accRes2 = await conn2.client.recvEncrypted();
    assert.equal(accRes2.type, 0x11);
    const resumeOffset = JSON.parse(accRes2.payload.toString('utf8')).resumeOffset;
    assert.equal(resumeOffset, splitPoint, `Expected resumeOffset=${splitPoint}, got ${resumeOffset}`);

    for (let off = resumeOffset; off < resumeData.length; off += 131072) {
      const slice = resumeData.subarray(off, Math.min(off + 131072, resumeData.length));
      const offBuf = Buffer.alloc(8);
      offBuf.writeBigUInt64BE(BigInt(off), 0);
      await conn2.client.sendEncrypted(0x13, Buffer.concat([uuidToBytes(tidRes), offBuf, slice]));
    }
    await conn2.client.sendEncrypted(0x14, Buffer.from(JSON.stringify({
      transferId: tidRes,
      sha256: resumeSha,
      totalBytes: resumeData.length,
    })));
    const ackRes = await conn2.client.recvEncrypted();
    assert.equal(ackRes.type, 0x15);
    assert.equal(JSON.parse(ackRes.payload.toString('utf8')).verified, true);
    assert.equal(sha256Buf(fs.readFileSync(path.join(macDest, resName))).toString('hex'), resumeSha);
    conn2.client.fsock.close();
    console.log('  [PASS] 6. Mid-stream TCP drop + QR expiry + reconnect + exact byte-offset resume verified!');

    console.log('=== All 6 Cross-Platform Interop Tests PASSED ===');
  } finally {
    try { proc.stdin.write('QUIT\n'); } catch {}
    proc.kill();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

run().catch((err) => {
  console.error('INTEROP TEST FAILED:', err);
  process.exit(1);
});
