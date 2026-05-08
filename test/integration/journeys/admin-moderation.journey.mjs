import { describe, it, before } from 'node:test';
import { GET, POST, PATCH, uniqueEmail, registerAndLogin, tokenFromAuthResponse, createProductPayload } from '../harness.mjs';

const assertEq = (a, e, msg) => { if (a !== e) throw new Error(msg || `expected ${e}, got ${a}`); };
const assertStatus = (res, expected, msg) => assertEq(res.status, expected, msg || `status ${res.status} !== ${expected}: ${JSON.stringify(res.body)}`);

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@bazaar.test';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';

let adminToken = null;
let adminLoginAttempts = 0;

async function loginAdminWithRetry(maxAttempts = 3, delayMs = 2000) {
  for (let i = 0; i < maxAttempts; i++) {
    const loginRes = await POST('/auth/login', { email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
    if (loginRes.status === 200) {
      adminToken = tokenFromAuthResponse(loginRes.body);
      return adminToken;
    }
    if (loginRes.status === 429) {
      adminLoginAttempts++;
      console.log(`Admin login rate limited, attempt ${i + 1}/${maxAttempts}, waiting ${delayMs}ms...`);
      await new Promise(r => setTimeout(r, delayMs));
      continue;
    }
    throw new Error(`Admin login failed: ${loginRes.status} ${JSON.stringify(loginRes.body)}`);
  }
  throw new Error(`Admin login failed after ${maxAttempts} attempts due to rate limiting`);
}

async function getUserId(token) {
  const meRes = await GET('/users/me', token);
  return meRes.body?.user_id ?? meRes.body?.id;
}

async function blockUser(userId) {
  return PATCH(`/admin/users/${userId}/status`, { user_status: 'blocked' }, adminToken);
}

describe('Journey D: Admin blocks user → Cross-service revocation', async () => {

  before(async () => {
    adminToken = await loginAdminWithRetry();
    console.log(`Admin logged in successfully after ${adminLoginAttempts} rate limit retries`);
  });

  it('admin can block a regular user', async () => {
    const { token, userId } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const actualUserId = await getUserId(token) || userId;
    const blockRes = await blockUser(actualUserId);
    assertStatus(blockRes, 204);
  });

  it('blocked user cannot access /users/me', async () => {
    const { token, userId } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const actualUserId = await getUserId(token) || userId;
    await blockUser(actualUserId);
    const blockedMeRes = await GET('/users/me', token);
    assertEq(blockedMeRes.status, 403, 'Blocked user accessing /users/me should return 403');
  });

  it('blocked user cannot create products', async () => {
    const { token, userId } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const actualUserId = await getUserId(token) || userId;
    await blockUser(actualUserId);
    const createRes = await POST('/catalog/me/products', createProductPayload({
      description: 'Should not be created',
      price: 1000,
      stock_quantity: 1,
    }), token);
    assertEq(createRes.status, 403, 'Blocked user creating product should return 403');
  });

  it('regular user cannot access admin endpoints', async () => {
    const { token, userId } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const adminRes = await PATCH(`/admin/users/${userId}/status`, { user_status: 'blocked' }, token);
    assertEq(adminRes.status, 403, 'Non-admin accessing admin endpoint should return 403');
  });

  it('active regular user can create products', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const createRes = await POST('/catalog/me/products', createProductPayload({
      description: 'Regular user selling',
      price: 500,
      stock_quantity: 1,
    }), token);
    assertEq(createRes.status, 201, 'Active regular users can sell in the marketplace');
  });

});
