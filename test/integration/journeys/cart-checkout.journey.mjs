import { describe, it, beforeEach } from 'node:test';
import { GET, POST, PATCH, uniqueEmail, registerAndLogin, createProductAndFetch, createCheckoutPayload } from '../harness.mjs';

const assert = (cond, msg) => { if (!cond) throw new Error(msg || 'assertion failed'); };
const assertEq = (a, e, msg) => { if (a !== e) throw new Error(msg || `expected ${e}, got ${a}`); };
const assertStatus = (res, expected, msg) => assertEq(res.status, expected, msg || `status ${res.status} !== ${expected}: ${JSON.stringify(res.body)}`);
const assertBodyContains = (res, key, msg) => assert(res.body && res.body[key] !== undefined, msg || `body missing key '${key}'`);

let productId;

async function setupProduct() {
  const { token: sellerToken } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
  const created = await createProductAndFetch(sellerToken, {
    description: 'Cart test product',
    price: 2500,
    category: 'technology',
    stock_quantity: 50,
  });
  productId = created.productId;
}

describe('Journey C: Cart → Checkout → Orders', async () => {

  beforeEach(async () => {
    await setupProduct();
  });

  it('buyer can add product to cart', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const addRes = await POST('/cart/items', { product_id: productId, quantity: 2 }, token);
    assertStatus(addRes, 201);
    assertBodyContains(addRes, 'items');
  });

  it('buyer can view their cart', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    await POST('/cart/items', { product_id: productId, quantity: 1 }, token);
    const cartRes = await GET('/cart', token);
    assertStatus(cartRes, 200);
    assertBodyContains(cartRes, 'items');
  });

  it('cart updates quantity for same product', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    await POST('/cart/items', { product_id: productId, quantity: 1 }, token);
    await PATCH(`/cart/items/${productId}`, { quantity: 3 }, token);
    const cartRes = await GET('/cart', token);
    const items = cartRes.body?.items || [];
    const item = items.find(i => i.product_id === productId);
    assert(item, 'product should be in cart');
    assertEq(item.quantity, 3);
  });

  it('checkout creates order', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    await POST('/cart/items', { product_id: productId, quantity: 2 }, token);
    const checkoutRes = await POST('/checkout', createCheckoutPayload({
      delivery_address: 'Test Street 123',
      delivery_city: 'Test City',
      delivery_province: 'Buenos Aires',
    }), token);
    assertStatus(checkoutRes, 201);
    assertBodyContains(checkoutRes, 'order_id');
  });

  it('order appears in buyer order list', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    await POST('/cart/items', { product_id: productId, quantity: 1 }, token);
    const checkoutRes = await POST('/checkout', createCheckoutPayload({
      delivery_address: 'Order Test Street',
      delivery_city: 'Order Test City',
      delivery_province: 'CABA',
    }), token);
    const orderId = checkoutRes.body?.order_id;
    assert(orderId, 'checkout should return order_id');
    const ordersRes = await GET('/orders', token);
    assertStatus(ordersRes, 200);
    const orders = ordersRes.body?.orders || [];
    assert(Array.isArray(orders), 'orders should be array');
    assert(orders.some(o => o.id === orderId), 'order should be in list');
  });

  it('order detail shows correct data', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    await POST('/cart/items', { product_id: productId, quantity: 1 }, token);
    const checkoutRes = await POST('/checkout', createCheckoutPayload({
      delivery_address: 'Detail Street',
      delivery_city: 'Detail City',
      delivery_province: 'CABA',
    }), token);
    const orderId = checkoutRes.body?.order_id;
    const detailRes = await GET(`/orders/${orderId}`, token);
    assertStatus(detailRes, 200);
    assertBodyContains(detailRes, 'id');
    assertBodyContains(detailRes, 'status');
  });

  it('checkout with empty cart fails', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    const checkoutRes = await POST('/checkout', createCheckoutPayload({
      delivery_address: 'Empty Cart Street',
      delivery_city: 'Empty City',
      delivery_province: 'CABA',
    }), token);
    assertEq(checkoutRes.status, 400);
  });

  it('cart persists across requests for same buyer', async () => {
    const { token } = await registerAndLogin(uniqueEmail(), 'TestPass123!');
    await POST('/cart/items', { product_id: productId, quantity: 1 }, token);
    const cartRes1 = await GET('/cart', token);
    const items1 = cartRes1.body?.items || [];
    await POST('/cart/items', { product_id: productId, quantity: 2 }, token);
    const cartRes2 = await GET('/cart', token);
    const items2 = cartRes2.body?.items || [];
    const item2 = items2.find(i => i.product_id === productId);
    assert(item2, 'product should still be in cart');
    const item1 = items1.find(i => i.product_id === productId);
    assert(item2.quantity > (item1?.quantity || 0), 'quantity should have increased');
  });

});
