import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { createService, extendExpiry } from './server.mjs';

test('remote account lifecycle, authorization, expiry, revocation and idempotent credit', async () => {
  let time = Date.UTC(2026, 0, 1);
  const password = 'Test-' + randomBytes(16).toString('hex');
  const service = await createService({ dbPath: ':memory:', adminUsername: 'testadmin', adminPassword: password, now: () => time });
  await new Promise(r => service.server.listen(0, '127.0.0.1', r));
  const url = 'http://127.0.0.1:' + service.server.address().port;
  const request = async (path, body, token, key) => {
    const res = await fetch(url + path, { method: body === undefined ? 'GET' : 'POST',
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}),
        ...(key ? { 'Idempotency-Key': key } : {}), 'X-Real-IP': 'forged-ip' },
      body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: res.status, body: await res.json() };
  };
  try {
    assert.equal((await request('/v1/status')).body.ip, '127.0.0.1', 'ignore spoofed IP');
    assert.equal((await request('/v1/login', {username:'testadmin',password:'wrongpass'})).status, 401);
    let admin = await request('/v1/login', {username:'testadmin',password});
    assert.equal(admin.status,200);
    const token = admin.body.token;
    const customerPassword = 'Customer-test-123';
    assert.equal((await request('/v1/admin/users',{username:'customer',password:customerPassword})).status,401);
    let created = await request('/v1/admin/users',{username:'customer',password:customerPassword},token);
    assert.equal(created.status,201); assert.equal(created.body.user.expiresAt,0);
    assert.equal((await request('/v1/register',{},token)).status,404);
    let login = await request('/v1/login',{username:'customer',password:customerPassword});
    assert.equal(login.status,403); assert.equal(login.body.code,'time_required'); assert.equal(login.body.passwordValid,true);
    const body = {username:'customer',unit:'hours',amount:10}, key = randomUUID();
    const credited = await request('/v1/admin/credit',body,token,key);
    assert.equal(credited.body.user.expiresAt,time+10*3600000);
    assert.deepEqual((await request('/v1/admin/credit',body,token,key)).body,credited.body);
    assert.equal((await request('/v1/admin/credit',{...body,amount:100},token,key)).status,409);
    assert.equal((await request('/v1/admin/credit',{...body,amount:-1},token,randomUUID())).status,400);
    login = await request('/v1/login',{username:'customer',password:customerPassword});
    assert.equal(login.status,200);
    assert.equal((await request('/v1/admin/users',undefined,login.body.token)).status,403);
    assert.equal((await request('/v1/session',undefined,login.body.token)).status,200);
    time += 11*3600000;
    assert.equal((await request('/v1/session',undefined,login.body.token)).body.code,'time_required');
    const permanent = await request('/v1/admin/credit',{username:'customer',unit:'permanent',amount:1},token,randomUUID());
    assert.equal(permanent.body.user.permanent,true);
    let secondDevice = await request('/v1/login',{username:'customer',password:customerPassword});
    assert.equal(secondDevice.status,200);
    assert.equal((await request('/v1/admin/account',{username:'customer',disabled:true},token)).status,200);
    assert.equal((await request('/v1/session',undefined,secondDevice.body.token)).status,401);
    assert.equal((await request('/v1/login',{username:'customer',password:customerPassword})).body.code,'account_disabled');
    const hashes = service.db.prepare('SELECT password_hash FROM users').all();
    assert.ok(hashes.every(r => !r.password_hash.includes(password) && !r.password_hash.includes(customerPassword)));
    assert.ok(!JSON.stringify((await request('/v1/admin/users',undefined,token)).body).includes('password_hash'));
    await request('/v1/logout',{},token);
    assert.equal((await request('/v1/session',undefined,token)).status,401);
  } finally { await service.close(); }
});
test('calendar months and years clamp to valid dates', () => {
  const jan31 = Date.UTC(2028,0,31,12);
  assert.equal(extendExpiry(jan31,0,1,'months'),Date.UTC(2028,1,29,12));
  assert.equal(extendExpiry(Date.UTC(2028,1,29),0,1,'years'),Date.UTC(2029,1,28));
  assert.equal(extendExpiry(1000,5000,1,'hours'),3605000);
});
test('login throttling rejects repeated guesses', async () => {
  const service = await createService({dbPath:':memory:',adminUsername:'admin',adminPassword:'test-password-only'});
  await new Promise(r=>service.server.listen(0,'127.0.0.1',r));
  try {
    let status;
    for(let i=0;i<16;i++) status=(await fetch('http://127.0.0.1:'+service.server.address().port+'/v1/login',
      {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'admin',password:'wrong-pass'})})).status;
    assert.equal(status,429);
  } finally { await service.close(); }
});
