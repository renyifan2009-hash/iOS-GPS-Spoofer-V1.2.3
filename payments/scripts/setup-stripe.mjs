#!/usr/bin/env node
// Optional. The server makes the three prices itself the first time each plan is bought, so this is
// only for seeing them in Stripe before anyone pays: $2.99 a month, $15 a year, $20 once. Safe to run
// again. Use a test key (sk_test_…) first.
//
//   STRIPE_SECRET_KEY=sk_test_… node scripts/setup-stripe.mjs
import { PLANS } from "../lib/license.js";
import { priceFor } from "../lib/server.js";

if (!process.env.STRIPE_SECRET_KEY) {
  console.error("Set STRIPE_SECRET_KEY (start with a test key, sk_test_…).");
  process.exit(1);
}
for (const plan of Object.keys(PLANS)) console.log(`${plan}: ${await priceFor(plan)}`);
