import assert from "node:assert/strict";
import test from "node:test";
import { priceFor } from "../lib/server.js";

/** A stand-in for the Stripe client: just the calls priceFor makes. */
function fakeStripe({ failFirstCreate = false } = {}) {
  const prices = [];
  const products = [];
  let creates = 0;
  return {
    get creates() { return creates; },
    prices: {
      list: async ({ lookup_keys }) => ({ data: prices.filter((p) => lookup_keys.includes(p.lookup_key)) }),
      create: async (params) => {
        creates += 1;
        if (failFirstCreate && creates === 1) {
          // Someone else made it a moment ago.
          prices.push({ id: "price_other", lookup_key: params.lookup_key, product: params.product });
          throw new Error("lookup_key already in use");
        }
        const price = { id: `price_${prices.length + 1}`, ...params };
        prices.push(price);
        return price;
      },
      _all: prices,
    },
    products: {
      list: async () => ({ data: products }),
      create: async (params) => {
        const product = { id: `prod_${products.length + 1}`, ...params };
        products.push(product);
        return product;
      },
      _all: products,
    },
  };
}

test("the first purchase of each plan makes its price, once, on one product", async () => {
  const stripe = fakeStripe();
  const monthly = await priceFor("monthly", stripe);
  const yearly = await priceFor("yearly", stripe);
  const lifetime = await priceFor("lifetime", stripe);
  assert.equal(await priceFor("monthly", stripe), monthly, "found the second time, not made again");
  const all = stripe.prices._all;
  assert.equal(all.length, 3);
  assert.equal(stripe.products._all.length, 1);
  assert.ok(all.every((p) => p.product === "prod_1"));
  const byKey = Object.fromEntries(all.map((p) => [p.lookup_key, p]));
  assert.equal(byKey.anywhere_monthly.unit_amount, 299);
  assert.deepEqual(byKey.anywhere_monthly.recurring, { interval: "month" });
  assert.equal(byKey.anywhere_yearly.unit_amount, 1500);
  assert.deepEqual(byKey.anywhere_yearly.recurring, { interval: "year" });
  assert.equal(byKey.anywhere_lifetime.unit_amount, 2000);
  assert.equal(byKey.anywhere_lifetime.recurring, undefined, "lifetime is a one-time price");
  assert.ok(all.every((p) => p.currency === "usd"));
  assert.notEqual(monthly, yearly);
  assert.notEqual(yearly, lifetime);
});

test("losing the race to make a price reads the winner's", async () => {
  const stripe = fakeStripe({ failFirstCreate: true });
  assert.equal(await priceFor("yearly", stripe), "price_other");
});

test("an unknown plan has no price", async () => {
  assert.equal(await priceFor("forever", fakeStripe()), null);
});
