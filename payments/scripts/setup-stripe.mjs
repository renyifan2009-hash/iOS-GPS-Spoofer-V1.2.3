#!/usr/bin/env node
// Creates (once) the AnyWhere Pro product and its three prices in the Stripe account whose secret key
// is in STRIPE_SECRET_KEY: $2.99 a month, $15 a year, $20 once. Safe to run again: prices are found by
// their lookup keys, and only missing ones are made. Use a test key (sk_test_…) first.
//
//   STRIPE_SECRET_KEY=sk_test_… node scripts/setup-stripe.mjs
import Stripe from "stripe";
import { PLANS } from "../lib/license.js";

const key = process.env.STRIPE_SECRET_KEY;
if (!key) {
  console.error("Set STRIPE_SECRET_KEY (start with a test key, sk_test_…).");
  process.exit(1);
}
const stripe = new Stripe(key);

const WANTED = {
  monthly: { unit_amount: 299, recurring: { interval: "month" }, nickname: "Monthly" },
  yearly: { unit_amount: 1500, recurring: { interval: "year" }, nickname: "Yearly" },
  lifetime: { unit_amount: 2000, nickname: "Lifetime" },
};

const existing = await stripe.prices.list({ lookup_keys: Object.values(PLANS).map((p) => p.lookupKey), limit: 10 });
let product = existing.data[0]?.product;
if (!product) {
  const found = await stripe.products.search({ query: "metadata['anywhere']:'pro'" }).catch(() => ({ data: [] }));
  product = found.data[0]?.id ?? (await stripe.products.create({
    name: "AnyWhere Pro",
    description: "Change your iPhone's location on the iPhone alone: teleport, natural drives with stops, joystick.",
    metadata: { anywhere: "pro" },
  })).id;
}
product = typeof product === "string" ? product : product.id;

for (const [plan, spec] of Object.entries(PLANS)) {
  const have = existing.data.find((p) => p.lookup_key === spec.lookupKey);
  if (have) {
    console.log(`${plan}: ${have.id} (already there)`);
    continue;
  }
  const price = await stripe.prices.create({ product, currency: "usd", lookup_key: spec.lookupKey, ...WANTED[plan] });
  console.log(`${plan}: ${price.id} (made)`);
}
console.log(`\nProduct ${product}. Next: turn on the customer portal (Settings ▸ Billing ▸ Customer portal) so people can cancel, and add the webhook (see README).`);
