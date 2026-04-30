import { describe, it } from 'node:test';
import { GET, POST, uniqueEmail, uniqueUsername, registerAndLogin } from '../harness.mjs';

const assert = (cond, msg) => { if (!cond) throw new Error(msg || 'assertion failed'); };
const assertEq = (a, e, msg) => { if (a !== e) throw new Error(msg || `expected ${e}, got ${a}`); };
const assertStatus = (res, expected, msg) => assertEq(res.status, expected, msg || `status ${res.status} !== ${expected}: ${JSON.stringify(res.body)}`);
const assertBodyContains = (res, key, msg) => assert(res.body && res.body[key] !== undefined, msg || `body missing key '${key}'`);

describe('Journey A: Register → Login → Profile', async () => {

  it('health check returns ok', async () => {
    const res = await GET('/readyz');
    assertStatus(res, 200);
    assertBodyContains(res, 'status');
  });

  it('register creates account and returns tokens', async () => {
    const payload = {
      email: uniqueEmail(),
      password: 'TestPass123!',
      username: uniqueUsername(),
    };
    const res = await POST('/auth/register', payload);
    assertStatus(res, 201);
    assertBodyContains(res, 'access_token');
    assertBodyContains(res, 'refresh_token');
  });

  it('login with valid credentials returns tokens', async () => {
    const email = uniqueEmail();
    const username = uniqueUsername();
    const password = 'TestPass123!';
    const regRes = await POST('/auth/register', { email, password, username });
    assertStatus(regRes, 201);
    const loginRes = await POST('/auth/login', { email, password });
    assertStatus(loginRes, 200);
    assertBodyContains(loginRes, 'access_token');
  });

  it('GET /users/me returns profile for authenticated user', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const meRes = await GET('/users/me', token);
    assertStatus(meRes, 200);
    assertBodyContains(meRes, 'email');
    assertBodyContains(meRes, 'user_id');
  });

  it('login fails with wrong password', async () => {
    const email = uniqueEmail();
    await POST('/auth/register', { email, password: 'TestPass123!', username: uniqueUsername() });
    const loginRes = await POST('/auth/login', { email, password: 'WrongPassword123!' });
    assertEq(loginRes.status, 401);
  });

  it('register fails with existing email', async () => {
    const email = uniqueEmail();
    const firstRes = await POST('/auth/register', { email, password: 'TestPass123!', username: uniqueUsername() });
    assertStatus(firstRes, 201);
    const dupRes = await POST('/auth/register', { email, password: 'TestPass123!', username: uniqueUsername() });
    assertEq(dupRes.status, 409);
  });

  it('unauthenticated /users/me returns 401', async () => {
    const res = await GET('/users/me');
    assertEq(res.status, 401);
  });

});
