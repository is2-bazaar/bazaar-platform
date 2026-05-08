import { readdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const JOURNEYS_DIR = join(__dirname, 'journeys');

const BASE_URL = process.env.LOCAL_API_BASE_URL || 'http://localhost:8080';

export const config = {
  baseUrl: BASE_URL,
  jwtSecret: process.env.JWT_SECRET || '',
  internalToken: process.env.INTERNAL_SERVICE_TOKEN || '',
};

export function uniqueEmail() {
  return `test${Date.now()}_${Math.random().toString(36).slice(2)}@bazaar.test`;
}

export function uniqueUsername() {
  return `u${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`.slice(0, 20);
}

export function uniqueProductName() {
  return `Product_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

export function uniqueIdempotencyKey() {
  return `idem_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

export async function request(path, options = {}) {
  const url = `${config.baseUrl}${path}`;
  const headers = {
    'Content-Type': 'application/json',
    ...options.headers,
  };

  const fetchOptions = {
    method: options.method || 'GET',
    headers,
  };

  if (options.body) {
    fetchOptions.body = JSON.stringify(options.body);
  }

  const response = await fetch(url, fetchOptions);
  let data;
  const text = await response.text();
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }

  return {
    status: response.status,
    headers: Object.fromEntries(response.headers.entries()),
    body: data,
  };
}

export async function authHeaders(token) {
  return { Authorization: `Bearer ${token}` };
}

export async function GET(path, token) {
  const headers = token ? await authHeaders(token) : {};
  return request(path, { headers });
}

export async function POST(path, body, token, extraHeaders = {}) {
  const headers = { ...extraHeaders };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  return request(path, { method: 'POST', headers, body });
}

export async function PATCH(path, body, token, extraHeaders = {}) {
  const headers = { ...extraHeaders };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  return request(path, { method: 'PATCH', headers, body });
}

export async function PUT(path, body, token, extraHeaders = {}) {
  const headers = { ...extraHeaders };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  return request(path, { method: 'PUT', headers, body });
}

export async function DELETE(path, token) {
  const headers = token ? await authHeaders(token) : {};
  return request(path, { method: 'DELETE', headers });
}

export function assert(condition, message) {
  if (!condition) {
    throw new Error(message || 'Assertion failed');
  }
}

export function assertEq(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(message || `Expected ${expected}, got ${actual}`);
  }
}

export function assertStatus(res, expected, message) {
  assertEq(res.status, expected, message || `Expected status ${expected}, got ${res.status}: ${JSON.stringify(res.body)}`);
}

export function assertContains(obj, key, message) {
  const val = typeof obj === 'object' && obj !== null ? obj[key] : undefined;
  if (val === undefined) {
    throw new Error(message || `Object does not contain key '${key}'`);
  }
}

export function assertBodyContains(res, key, message) {
  assertContains(res.body, key, message || `Response body does not contain key '${key}'`);
}

export function delay(ms) {
  return new Promise(r => setTimeout(r, ms));
}

export function tokenFromAuthResponse(body) {
  return body?.access_token || body?.accessToken;
}

export function refreshTokenFromAuthResponse(body) {
  return body?.refresh_token || body?.refreshToken;
}

export function decodeJWT(token) {
  if (!token) {
    return {};
  }

  const [, payload] = token.split('.');
  if (!payload) {
    return {};
  }

  try {
    return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  } catch {
    return {};
  }
}

export function userIdFromToken(token) {
  const sub = decodeJWT(token).sub;
  const parsed = Number(sub);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export function createProductPayload(overrides = {}) {
  return {
    name: uniqueProductName(),
    description: 'Test product description',
    price: 1999,
    category: 'technology',
    stock_quantity: 10,
    image_bucket_url: '',
    status: 'active',
    ...overrides,
  };
}

export function createCheckoutPayload(overrides = {}) {
  return {
    idempotency_key: uniqueIdempotencyKey(),
    delivery_address: 'Test Street 123',
    delivery_city: 'Test City',
    delivery_province: 'CABA',
    ...overrides,
  };
}

export function getProductId(product) {
  return product?.id ?? product?.ID;
}

export function getProductsArray(body) {
  if (Array.isArray(body)) {
    return body;
  }
  if (Array.isArray(body?.products)) {
    return body.products;
  }
  return [];
}

export async function createProductAndFetch(token, overrides = {}) {
  const payload = createProductPayload(overrides);
  const createRes = await POST('/catalog/me/products', payload, token);
  assertStatus(createRes, 201, `Create product failed with ${createRes.status}: ${JSON.stringify(createRes.body)}`);

  const listRes = await GET('/catalog/me/products', token);
  assertStatus(listRes, 200, `List seller products failed with ${listRes.status}: ${JSON.stringify(listRes.body)}`);

  const product = getProductsArray(listRes.body).find(item => item.name === payload.name);
  assert(product, `created product ${payload.name} should be present in seller list`);

  return {
    payload,
    product,
    productId: getProductId(product),
    createRes,
    listRes,
  };
}

export async function registerAndLogin(email, password) {
  const registerRes = await POST('/auth/register', {
    email,
    password,
    username: uniqueUsername(),
  });

  if (registerRes.status !== 201 && registerRes.status !== 200) {
    throw new Error(`Register failed: ${registerRes.status} ${JSON.stringify(registerRes.body)}`);
  }

  const token = tokenFromAuthResponse(registerRes.body);
  if (!token) {
    throw new Error(`Register response did not include access token: ${JSON.stringify(registerRes.body)}`);
  }

  return {
    token,
    refreshToken: refreshTokenFromAuthResponse(registerRes.body),
    userId: userIdFromToken(token),
    email,
    registerRes,
  };
}

export async function importJourneyTests(t, harness) {
  const files = readdirSync(JOURNEYS_DIR).filter(f => f.endsWith('.mjs'));
  for (const file of files.sort()) {
    const mod = await import(`./journeys/${file}`);
    if (mod.default) {
      await mod.default(t, harness);
    }
  }
}
