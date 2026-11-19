import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { randomBytes, scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const derive = promisify(scrypt);
const digest = s => createHash('sha256').update(s).digest('hex');
const usernameOK = s => typeof s === 'string' && /^[A-Za-z0-9_.-]{3,64}$/.test(s);
const passwordOK = s => typeof s === 'string' && s.length >= 8 && Buffer.byteLength(s) <= 128;
class APIError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
const fail = (status, code) => { throw new APIError(status, code); };
async function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const key = await derive(password, salt, 64, { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });
  return salt + ':' + key.toString('hex');
}
async function matches(password, stored) {
  const [salt, expected] = stored.split(':');
  const actual = await derive(password, salt, 64, { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });
  return timingSafeEqual(actual, Buffer.from(expected, 'hex'));
}
export function extendExpiry(now, current, amount, unit) {
  if (!Number.isSafeInteger(amount) || amount < 1 || amount > 1000000) fail(400, 'invalid_duration');
  const start = Math.max(now, current || 0);
  let result;
  if (unit === 'hours' || unit === 'days') result = start + amount * (unit === 'hours' ? 3600000 : 86400000);
  else if (unit === 'months' || unit === 'years') {
    const d = new Date(start), day = d.getUTCDate();
    d.setUTCDate(1);
    d.setUTCMonth(d.getUTCMonth() + amount * (unit === 'years' ? 12 : 1));
    const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
    d.setUTCDate(Math.min(day, last)); result = d.getTime();
  } else fail(400, 'invalid_duration');
  if (!Number.isFinite(result) || result > Date.UTC(9999, 11, 31)) fail(400, 'invalid_duration');
  return result;
}
export async function createService({ dbPath, adminUsername, adminPassword, now = Date.now, trustedProxies = [] }) {
  if (dbPath !== ':memory:') mkdirSync(dirname(resolve(dbPath)), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS users(username TEXT PRIMARY KEY, password_hash TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('admin','customer')), expires_at INTEGER NOT NULL DEFAULT 0,
      permanent INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS sessions(token_hash TEXT PRIMARY KEY, username TEXT NOT NULL REFERENCES users(username),
      expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS credits(request_id TEXT PRIMARY KEY, admin TEXT NOT NULL, body TEXT NOT NULL, response TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, at INTEGER, actor TEXT, action TEXT, target TEXT, ip TEXT);
  `);
  if (!db.prepare("SELECT 1 FROM users WHERE role='admin'").get()) {
    if (!usernameOK(adminUsername) || !passwordOK(adminPassword)) throw new Error('Set BIGVIP_ADMIN_USERNAME and BIGVIP_ADMIN_PASSWORD (8–128 bytes).');
    db.prepare("INSERT INTO users(username,password_hash,role,permanent) VALUES(?,?,'admin',1)")
      .run(adminUsername, await hashPassword(adminPassword));
  }
  const dummyHash = await hashPassword(randomBytes(32).toString('hex'));
  const attempts = new Map();
  const active = u => u && !u.disabled && (u.role === 'admin' || !!u.permanent || u.expires_at > now());
  const publicUser = u => ({ username: u.username, role: u.role, expiresAt: u.expires_at,
    permanent: !!u.permanent, disabled: !!u.disabled });
  const ipOf = req => {
    const peer = req.socket.remoteAddress || 'unknown';
    // A trusted single reverse proxy must overwrite, not append, X-Real-IP.
    return trustedProxies.includes(peer) && typeof req.headers['x-real-ip'] === 'string'
      ? req.headers['x-real-ip'].slice(0, 64) : peer;
  };
  const limit = (key, max) => {
    const t = now();
    if (attempts.size >= 10000) {
      for (const [k,v] of attempts) if (v.until <= t) attempts.delete(k);
      if (attempts.size >= 10000 && !attempts.has(key)) fail(429, 'rate_limited');
    }
    let value = attempts.get(key);
    if (!value || value.until <= t) value = { count: 0, until: t + 15 * 60000 };
    value.count++; attempts.set(key, value);
    if (value.count > max) fail(429, 'rate_limited');
  };
  const readBody = async req => {
    if (!(req.headers['content-type'] || '').startsWith('application/json')) fail(415, 'json_required');
    let size = 0, chunks = [];
    for await (const chunk of req) { size += chunk.length; if (size > 16384) fail(413, 'body_too_large'); chunks.push(chunk); }
    try {
      const b = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!b || typeof b !== 'object' || Array.isArray(b)) fail(400, 'invalid_json');
      return b;
    } catch { fail(400, 'invalid_json'); }
  };
  const send = (res, status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff' });
    res.end(JSON.stringify(body));
  };
  const audit = (actor, action, target, ip) => db.prepare('INSERT INTO audit(at,actor,action,target,ip) VALUES(?,?,?,?,?)')
    .run(now(), actor, action, target, ip);
  const authenticate = req => {
    const raw = req.headers.authorization || '';
    if (!/^Bearer [a-f0-9]{64}$/.test(raw)) fail(401, 'unauthorized');
    const tokenHash = digest(raw.slice(7));
    const session = db.prepare('SELECT * FROM sessions WHERE token_hash=? AND expires_at>?').get(tokenHash, now());
    if (!session) fail(401, 'unauthorized');
    const user = db.prepare('SELECT * FROM users WHERE username=?').get(session.username);
    if (!active(user)) fail(403, user?.disabled ? 'account_disabled' : 'time_required');
    return { user, tokenHash };
  };
  const server = http.createServer(async (req, res) => {
    const ip = ipOf(req);
    try {
      const route = new URL(req.url, 'http://service').pathname;
      if (req.method === 'GET' && route === '/v1/status') return send(res, 200, { ip, serverTime: now() });
      if (req.method === 'POST' && route === '/v1/login') {
        limit('ip:' + ip, 60);
        const b = await readBody(req);
        if (!usernameOK(b.username) || !passwordOK(b.password)) fail(401, 'invalid_credentials');
        limit('user:' + b.username, 15);
        const user = db.prepare('SELECT * FROM users WHERE username=?').get(b.username);
        const valid = await matches(b.password, user?.password_hash || dummyHash);
        if (!user || !valid) return send(res, 401, { code: 'invalid_credentials', passwordValid: false, ip });
        if (!active(user)) return send(res, 403, { code: user.disabled ? 'account_disabled' : 'time_required', passwordValid: true, ip });
        const token = randomBytes(32).toString('hex'), expires = now() + 12 * 3600000;
        db.prepare('DELETE FROM sessions WHERE expires_at<=?').run(now());
        db.prepare('INSERT INTO sessions VALUES(?,?,?)').run(digest(token), user.username, expires);
        audit(user.username, 'login', user.username, ip);
        return send(res, 200, { token, tokenExpiresAt: expires, passwordValid: true, ip, user: publicUser(user), serverTime: now() });
      }
      const { user, tokenHash } = authenticate(req);
      if (req.method === 'GET' && route === '/v1/session')
        return send(res, 200, { user: publicUser(user), ip, serverTime: now() });
      if (req.method === 'POST' && route === '/v1/logout') {
        db.prepare('DELETE FROM sessions WHERE token_hash=?').run(tokenHash);
        return send(res, 200, { ok: true });
      }
      if (!route.startsWith('/v1/admin/')) fail(404, 'not_found');
      if (user.role !== 'admin') fail(403, 'admin_required');
      limit('admin:' + user.username, 300);
      if (req.method === 'GET' && route === '/v1/admin/users') {
        const list = db.prepare("SELECT * FROM users WHERE role='customer' ORDER BY username LIMIT 1000").all();
        return send(res, 200, { users: list.map(publicUser) });
      }
      const b = await readBody(req);
      if (!usernameOK(b.username)) fail(400, 'invalid_username');
      if (req.method === 'POST' && route === '/v1/admin/users') {
        if (!passwordOK(b.password)) fail(400, 'invalid_password');
        if (db.prepare('SELECT 1 FROM users WHERE username=?').get(b.username)) fail(409, 'username_exists');
        const hash = await hashPassword(b.password);
        try { db.prepare("INSERT INTO users(username,password_hash,role) VALUES(?,?,'customer')").run(b.username, hash); }
        catch { fail(409, 'username_exists'); }
        audit(user.username, 'create', b.username, ip);
        return send(res, 201, { user: publicUser(db.prepare('SELECT * FROM users WHERE username=?').get(b.username)) });
      }
      const customer = db.prepare("SELECT * FROM users WHERE username=? AND role='customer'").get(b.username);
      if (!customer) fail(404, 'user_not_found');
      if (req.method === 'POST' && route === '/v1/admin/credit') {
        const requestID = req.headers['idempotency-key'];
        if (typeof requestID !== 'string' || !/^[a-f0-9-]{36}$/i.test(requestID)) fail(400, 'request_id_required');
        const bodyKey = JSON.stringify({ username: b.username, unit: b.unit, amount: b.amount });
        const old = db.prepare('SELECT * FROM credits WHERE request_id=?').get(requestID);
        if (old) {
          if (old.admin !== user.username || old.body !== bodyKey) fail(409, 'request_id_conflict');
          return send(res, 200, JSON.parse(old.response));
        }
        const permanent = b.unit === 'permanent' || !!customer.permanent;
        if (b.unit !== 'permanent') extendExpiry(now(), customer.expires_at, b.amount, b.unit);
        const expiry = permanent ? customer.expires_at : extendExpiry(now(), customer.expires_at, b.amount, b.unit);
        db.exec('BEGIN IMMEDIATE');
        try {
          db.prepare('UPDATE users SET expires_at=?, permanent=? WHERE username=?').run(expiry, permanent ? 1 : 0, b.username);
          const result = { user: publicUser(db.prepare('SELECT * FROM users WHERE username=?').get(b.username)) };
          db.prepare('INSERT INTO credits VALUES(?,?,?,?)').run(requestID, user.username, bodyKey, JSON.stringify(result));
          audit(user.username, 'credit:' + b.unit + ':' + String(b.amount || 0), b.username, ip);
          db.exec('COMMIT');
          return send(res, 200, result);
        } catch (e) { db.exec('ROLLBACK'); throw e; }
      }
      if (req.method === 'POST' && route === '/v1/admin/account') {
        if (typeof b.disabled !== 'boolean' && b.password === undefined) fail(400, 'invalid_update');
        if (b.password !== undefined) {
          if (!passwordOK(b.password)) fail(400, 'invalid_password');
          db.prepare('UPDATE users SET password_hash=? WHERE username=?').run(await hashPassword(b.password), b.username);
        }
        if (typeof b.disabled === 'boolean') db.prepare('UPDATE users SET disabled=? WHERE username=?').run(b.disabled ? 1 : 0, b.username);
        db.prepare('DELETE FROM sessions WHERE username=?').run(b.username);
        audit(user.username, 'update_account', b.username, ip);
        return send(res, 200, { user: publicUser(db.prepare('SELECT * FROM users WHERE username=?').get(b.username)) });
      }
      fail(404, 'not_found');
    } catch (e) {
      if (!res.headersSent) send(res, e.status || 500, { code: e.code || 'server_error', ip });
    }
  });
  server.requestTimeout = 15000; server.headersTimeout = 10000;
  return { server, db, close: async () => { server.closeAllConnections(); await new Promise(r => server.close(r)); db.close(); } };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const service = await createService({
    dbPath: process.env.BIGVIP_DB || './data/bigvip.sqlite',
    adminUsername: process.env.BIGVIP_ADMIN_USERNAME || 'DfnA0hqi751',
    adminPassword: process.env.BIGVIP_ADMIN_PASSWORD,
    trustedProxies: (process.env.BIGVIP_TRUSTED_PROXIES || '').split(',').filter(Boolean)
  });
  service.server.listen(Number(process.env.PORT || 8080), process.env.HOST || '127.0.0.1',
    () => console.log('bigvip API listening; put HTTPS in front before use with iPhone.'));
}
