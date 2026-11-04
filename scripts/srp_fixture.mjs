#!/usr/bin/env node
// Generates Tests/DoormanCoreTests/SRPFixture.swift: known-good SRP and AES values, computed two ways
// that don't share code with Doorman.
//   1. Node BigInt + node:crypto, written from RFC 5054 and the formulas below.
//   2. If you pass the path of Apple's unpacked extension, Apple's own SecretSession runs on the same
//      inputs in a sandboxed vm. Apple's code isn't copied into this repo, only the numbers it gives.
// Usage: node scripts/srp_fixture.mjs [path/to/extension/background.js]
import crypto from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';

const hex = (b) => Buffer.from(b).toString('hex');
const toBytes = (n) => { let h = n.toString(16); if (h.length % 2) h = '0' + h; return Buffer.from(h, 'hex'); };
const pad = (n, len = 384) => { const b = toBytes(n); return Buffer.concat([Buffer.alloc(Math.max(0, len - b.length)), b]); };
const H = (...parts) => { const h = crypto.createHash('sha256'); for (const p of parts) h.update(p); return h.digest(); };
const int = (b) => BigInt('0x' + hex(b));
const mod = (a, m) => ((a % m) + m) % m;
const powmod = (b, e, m) => { let r = 1n; b = mod(b, m); while (e > 0n) { if (e & 1n) r = (r * b) % m; b = (b * b) % m; e >>= 1n; } return r; };

const N = BigInt('0x' + `FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD
EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F
83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510
15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C
BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF`.replace(/\s/g, ''));
const g = 5n;

function compute({ I, a, b, salt, pin, base64 }) {
  const tid = base64 ? I.toString('base64') : '0x' + hex(I);
  const k = int(H(toBytes(N), pad(g)));
  const x = int(H(salt, H(Buffer.from(tid + ':' + pin))));
  const v = powmod(g, x, N);
  const A = powmod(g, int(a), N);
  const B = mod(k * v + powmod(g, int(b), N), N);
  const u = int(H(pad(A), pad(B)));
  const S = powmod(mod(B - mod(k * v, N), N), int(a) + u * x, N);
  const Sserver = powmod(mod(A * powmod(v, u, N), N), int(b), N);
  if (S !== Sserver) throw new Error('client and server disagree');
  const K = H(toBytes(S));
  const hN = H(toBytes(N)), hG = H(pad(g));
  const xored = Buffer.from(hN.map((c, i) => c ^ hG[i]));
  const M = H(xored, H(Buffer.from(tid)), salt, toBytes(A), toBytes(B), K);
  const HAMK = H(toBytes(A), M, K);
  return { A: hex(toBytes(A)), B: hex(toBytes(B)), K: hex(K), M: hex(M), HAMK: hex(HAMK), v: hex(toBytes(v)) };
}

function appleCheck(path, input, node) {
  const src = fs.readFileSync(path, 'utf8');
  const start = src.indexOf('var sjcl=');
  const end = src.indexOf('const ContextState=');
  if (start < 0 || end < 0) throw new Error('could not find Apple session code');
  const words = (buf) => { const out = []; for (let i = 0; i < buf.length; i += 4) out.push(buf.readInt32BE(i)); return out; };
  // sjcl seeds itself while loading, so the fixed values only start once it has loaded.
  let queue = [];
  const sandbox = { self: { crypto: { getRandomValues: (a) => { if (!queue.length) return crypto.getRandomValues(a); const w = words(queue.shift()); for (let i = 0; i < a.length; i++) a[i] = w[i]; return a; } } }, ErrCodes: {}, console };
  sandbox.window = sandbox.self;
  vm.createContext(sandbox);
  vm.runInContext(src.slice(start, end) + ';this.SecretSession=SecretSession;this.sjcl=sjcl;', sandbox);
  queue = [input.I, input.a];
  const session = new sandbox.SecretSession({ shouldUseBase64: Boolean(input.base64), secretSessionVersion: 1 });
  session.setPin(input.pin);
  const m0 = JSON.parse(Buffer.from(session.initialMessage(), 'base64').toString());
  const wire = (h) => (input.base64 ? Buffer.from(h, 'hex').toString('base64') : '0x' + h);
  const msg1 = Buffer.from(JSON.stringify({ TID: m0.TID, MSG: 1, s: wire(hex(input.salt)), B: wire(node.B), VER: '1.0', PROTO: 1 })).toString('base64');
  const m2 = JSON.parse(Buffer.from(session.processMessage(msg1), 'base64').toString());
  const encKey = sandbox.sjcl.codec.hex.fromBits(session.encKey);
  const unwire = (v) => (input.base64 ? Buffer.from(v, 'base64').toString('hex') : v.replace(/^0x/, ''));
  return { tid: m0.TID, A: unwire(m0.A), M: unwire(m2.M), encKey, hamk: sandbox.sjcl.codec.hex.fromBits(session.hamk) };
}

// Fixed inputs. Case 2 gives A a leading zero byte's worth of awkwardness by using a tiny a.
const cases = [
  { name: 'typical', I: Buffer.from('a1b2c3d4e5f60718293a4b5c6d7e8f90', 'hex'), a: Buffer.from('0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20', 'hex'),
    b: Buffer.from('f0e0d0c0b0a090807060504030201000ffeeddccbbaa99887766554433221100', 'hex'), salt: Buffer.from('00112233445566778899aabbccddeeff', 'hex'), pin: '123456' },
  { name: 'other pin', I: Buffer.from('ffffffffffffffffffffffffffffffff', 'hex'), a: Buffer.from('7f'.repeat(32), 'hex'),
    b: Buffer.from('13'.repeat(32), 'hex'), salt: Buffer.from('deadbeefdeadbeefdeadbeefdeadbeef', 'hex'), pin: '000000' },
  // What macOS actually asks for: the helper's capabilities say shouldUseBase64.
  { name: 'base64 mode', base64: true, I: Buffer.from('a1b2c3d4e5f60718293a4b5c6d7e8f90', 'hex'), a: Buffer.from('0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20', 'hex'),
    b: Buffer.from('f0e0d0c0b0a090807060504030201000ffeeddccbbaa99887766554433221100', 'hex'), salt: Buffer.from('00112233445566778899aabbccddeeff', 'hex'), pin: '482913' },
];

let appleVerified = false;
const rows = cases.map((c) => {
  const node = compute(c);
  if (process.argv[2]) {
    const apple = appleCheck(process.argv[2], c, node);
    for (const [label, ours, theirs] of [['A', node.A, apple.A], ['M', node.M, apple.M], ['enc key', node.K.slice(0, 32), apple.encKey], ['HAMK', node.HAMK, apple.hamk], ['TID', c.base64 ? c.I.toString('base64') : '0x' + hex(c.I), apple.tid]]) {
      if (ours !== theirs) throw new Error(`Apple's client disagrees on ${label} for ${c.name}: ${ours} vs ${theirs}`);
    }
    appleVerified = true;
  }
  return { ...c, ...node };
});

const key = Buffer.from(rows[0].K.slice(0, 32), 'hex');
const iv = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex');
const plain = Buffer.from('{"ACT":2,"URL":"example.com","USR":"me"}');
const cipher = crypto.createCipheriv('aes-128-gcm', key, iv);
const ct = Buffer.concat([cipher.update(plain), cipher.final()]);
const tag = cipher.getAuthTag();

// A reply as Apple's helper writes it: IV + ciphertext + tag.
const replyPlain = Buffer.from('{"STATUS":0,"Entries":[{"USR":"me","PWD":"fixture-password","sites":["example.com"]}]}');
const replyIV = Buffer.from('0f0e0d0c0b0a09080706050403020100', 'hex');
const c2 = crypto.createCipheriv('aes-128-gcm', key, replyIV);
const ct2 = Buffer.concat([c2.update(replyPlain), c2.final()]);
const reply = Buffer.concat([replyIV, ct2, c2.getAuthTag()]);

const swift = `// Generated by scripts/srp_fixture.mjs. Don't edit by hand.
// Apple's own client agreed with these values when generated: ${appleVerified}.
enum SRPFixture {
    struct Row { let name, I, a, salt, pin, A, B, K, M, HAMK: String; let base64: Bool }
    static let rows = [
${rows.map((r) => `        Row(name: "${r.name}", I: "${hex(r.I)}", a: "${hex(r.a)}", salt: "${hex(r.salt)}", pin: "${r.pin}",
            A: "${r.A}",
            B: "${r.B}",
            K: "${r.K}", M: "${r.M}", HAMK: "${r.HAMK}", base64: ${Boolean(r.base64)}),`).join('\n')}
    ]
    static let aesKey = "${hex(key)}"
    static let aesIV = "${hex(iv)}"
    static let aesPlain = ${JSON.stringify(plain.toString())}
    static let aesOut = "${hex(Buffer.concat([ct, tag, iv]))}"
    static let replySDATA = "${hex(reply)}"
    static let replyPlain = ${JSON.stringify(replyPlain.toString())}
    static let appleVerified = ${appleVerified}
}
`;
fs.writeFileSync(new URL('../Tests/DoormanCoreTests/SRPFixture.swift', import.meta.url), swift);
console.log('fixture written; Apple client verified:', appleVerified);
