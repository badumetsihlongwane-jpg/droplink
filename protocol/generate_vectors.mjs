#!/usr/bin/env node
/**
 * Generates canonical DLSP/1 cryptographic test vectors using Node.js built-in crypto.
 * Verified identically by Swift (macOS), Kotlin (Android), and Node.js protocol tests.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function hex(buf) {
  return Buffer.from(buf).toString('hex');
}

function hmacSha256(keyBuf, text) {
  return crypto.createHmac('sha256', keyBuf).update(text, 'utf8').digest();
}

function sha256(bufOrText) {
  return crypto.createHash('sha256').update(bufOrText).digest();
}

function hkdfSha256(ikm, salt, info, length = 32) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), length));
}

function encryptFrame(key, direction, seq, plaintext) {
  const nonce = Buffer.alloc(12);
  nonce.writeUInt32BE(direction, 0);
  nonce.writeBigUInt64BE(BigInt(seq), 4);

  const aad = Buffer.alloc(16);
  aad.writeUInt32BE(direction, 0);
  aad.writeBigUInt64BE(BigInt(seq), 4);
  aad.writeUInt32BE(plaintext.length, 12);

  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aad);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    nonceHex: hex(nonce),
    aadHex: hex(aad),
    ciphertextAndTagHex: hex(Buffer.concat([ct, tag])),
  };
}

// Deterministic P-256 keys (fixed 32-byte private scalars for reproducible vectors)
const clientPrivHex = '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';
const serverPrivHex = 'ffeeddccbbaa00998877665544332211ffeeddccbbaa00998877665544332211';

const clientEcdh = crypto.createECDH('prime256v1');
clientEcdh.setPrivateKey(Buffer.from(clientPrivHex, 'hex'));
const clientPub = clientEcdh.getPublicKey(); // 65 bytes uncompressed 0x04||X||Y

const serverEcdh = crypto.createECDH('prime256v1');
serverEcdh.setPrivateKey(Buffer.from(serverPrivHex, 'hex'));
const serverPub = serverEcdh.getPublicKey();

const ecdhSharedClient = clientEcdh.computeSecret(serverPub);
const ecdhSharedServer = serverEcdh.computeSecret(clientPub);
if (!ecdhSharedClient.equals(ecdhSharedServer)) {
  throw new Error('ECDH shared secret mismatch!');
}

const sessionId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const mode = 'pair';
const deviceId = '550e8400-e29b-41d4-a716-446655440000';
const psk = Buffer.from('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'hex');
const clientNonce = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const serverNonce = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

const clientProofMsg = `DLSP1-CLIENT|${sessionId}|${mode}|${clientNonce}|${hex(clientPub)}|${deviceId}`;
const clientProof = hmacSha256(psk, clientProofMsg);

const serverProofMsg = `DLSP1-SERVER|${sessionId}|${mode}|${clientNonce}|${serverNonce}|${hex(clientPub)}|${hex(serverPub)}`;
const serverProof = hmacSha256(psk, serverProofMsg);

const ikm = Buffer.concat([ecdhSharedClient, psk]);
const salt = sha256(Buffer.from(`DLSP1-SALT|${sessionId}|${clientNonce}|${serverNonce}`, 'utf8'));
const c2sKey = hkdfSha256(ikm, salt, 'DLSP1-C2S-KEY', 32);
const s2cKey = hkdfSha256(ikm, salt, 'DLSP1-S2C-KEY', 32);
const reconnectKey = hkdfSha256(ikm, salt, 'DLSP1-RECONNECT', 32);

const samplePlaintext1 = Buffer.concat([Buffer.from([0x01]), Buffer.from('{"ts":1700000000000}', 'utf8')]);
const sampleFrame1 = encryptFrame(c2sKey, 1, 0, samplePlaintext1);

const samplePlaintext2 = Buffer.concat([Buffer.from([0x02]), Buffer.from('{"ts":1700000000000}', 'utf8')]);
const sampleFrame2 = encryptFrame(s2cKey, 2, 0, samplePlaintext2);

const qrUri = `droplink://pair?v=1&h=192.168.1.42,10.0.0.5&p=54321&s=${sessionId}&k=${psk.toString('base64url')}&e=1900000000&n=MacBook%20Air`;

const vectors = {
  protocol: 'DLSP/1',
  sessionId,
  mode,
  deviceId,
  pskHex: hex(psk),
  pskBase64Url: psk.toString('base64url'),
  clientPrivHex,
  clientPubHex: hex(clientPub),
  serverPrivHex,
  serverPubHex: hex(serverPub),
  ecdhSharedHex: hex(ecdhSharedClient),
  clientNonce,
  serverNonce,
  clientProofHex: hex(clientProof),
  serverProofHex: hex(serverProof),
  saltHex: hex(salt),
  c2sKeyHex: hex(c2sKey),
  s2cKeyHex: hex(s2cKey),
  reconnectKeyHex: hex(reconnectKey),
  frameC2SSeq0: {
    direction: 1,
    seq: 0,
    plaintextHex: hex(samplePlaintext1),
    ...sampleFrame1,
  },
  frameS2CSeq0: {
    direction: 2,
    seq: 0,
    plaintextHex: hex(samplePlaintext2),
    ...sampleFrame2,
  },
  qrUri,
};

const outPath = path.join(__dirname, 'test_vectors.json');
fs.writeFileSync(outPath, JSON.stringify(vectors, null, 2) + '\n');
console.log('Generated test vectors at', outPath);
