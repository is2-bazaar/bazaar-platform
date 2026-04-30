import { describe, it } from 'node:test';
import { GET, uniqueEmail, registerAndLogin, createProductAndFetch, getProductId, getProductsArray } from '../harness.mjs';

const assert = (cond, msg) => { if (!cond) throw new Error(msg || 'assertion failed'); };
const assertEq = (a, e, msg) => { if (a !== e) throw new Error(msg || `expected ${e}, got ${a}`); };
const assertStatus = (res, expected, msg) => assertEq(res.status, expected, msg || `status ${res.status} !== ${expected}: ${JSON.stringify(res.body)}`);
const assertBodyContains = (res, key, msg) => assert(res.body && res.body[key] !== undefined, msg || `body missing key '${key}'`);

describe('Journey B: Seller creates product → Public catalog', async () => {

  it('seller can create a product', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const { product, productId } = await createProductAndFetch(token, {
      description: 'Test product description',
      price: 1999,
      category: 'technology',
      stock_quantity: 10,
    });
    assert(productId, 'product should have id');
    assertBodyContains({ body: product }, 'name');
  });

  it('seller can list their own products', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const { productId } = await createProductAndFetch(token, {
      description: 'Test product',
      price: 2999,
      category: 'entertainment',
      stock_quantity: 5,
    });
    const listRes = await GET('/catalog/me/products', token);
    assertStatus(listRes, 200);
    const products = getProductsArray(listRes.body);
    assert(Array.isArray(products), 'products should be array');
    assert(products.some(p => getProductId(p) === productId), 'created product should be in seller list');
  });

  it('product appears in public catalog', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const { productId } = await createProductAndFetch(token, {
      description: 'Public test product',
      price: 1499,
      category: 'furniture',
      stock_quantity: 15,
    });
    const catalogRes = await GET('/catalog/products');
    assertStatus(catalogRes, 200);
    const products = getProductsArray(catalogRes.body);
    assert(Array.isArray(products), 'products should be array');
    assert(products.some(p => getProductId(p) === productId), 'product should be in catalog');
  });

  it('product detail shows correct data', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const { payload, productId } = await createProductAndFetch(token, {
      description: 'Detail test product',
      price: 5999,
      category: 'technology',
      stock_quantity: 20,
    });
    const detailRes = await GET(`/catalog/products/${productId}`);
    assertStatus(detailRes, 200);
    assertEq(detailRes.body.name, payload.name);
    assertEq(detailRes.body.price, 5999);
  });

  it('unauthenticated user can list public catalog', async () => {
    const res = await GET('/catalog/products');
    assertStatus(res, 200);
  });

  it('unauthenticated user can view product detail', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const { productId } = await createProductAndFetch(token, {
      description: 'Public product',
      price: 999,
      category: 'clothes',
      stock_quantity: 3,
    });
    const detailRes = await GET(`/catalog/products/${productId}`);
    assertStatus(detailRes, 200);
  });

});
