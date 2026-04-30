import { describe } from 'node:test';

const journeyFiles = [
  './journeys/auth.journey.mjs',
  './journeys/catalog.journey.mjs',
  './journeys/cart-checkout.journey.mjs',
  './journeys/admin-moderation.journey.mjs',
];

describe('Integration Test Suite', async () => {
  for (const file of journeyFiles) {
    const mod = await import(file);
    if (mod.default) {
      await mod.default();
    }
  }
});