// What every endpoint shares: Stripe, the request body, answers, and making sure a paying customer has
// a license key.
import Stripe from "stripe";
import { PLANS, makeKey, secretFor } from "./license.js";

let client;
export function stripe() {
  if (!process.env.STRIPE_SECRET_KEY) throw new Error("STRIPE_SECRET_KEY isn't set");
  client ??= new Stripe(process.env.STRIPE_SECRET_KEY);
  return client;
}

/** Where this server is reached, for Stripe's return links. */
export function baseURL(req) {
  if (process.env.PUBLIC_URL) return process.env.PUBLIC_URL.replace(/\/$/, "");
  return `https://${req.headers["x-forwarded-host"] ?? req.headers.host}`;
}

export async function rawBody(req) {
  if (typeof req.body === "string") return req.body;
  if (Buffer.isBuffer(req.body)) return req.body.toString("utf8");
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

export async function jsonBody(req) {
  if (req.body && typeof req.body === "object" && !Buffer.isBuffer(req.body)) return req.body;
  try {
    return JSON.parse((await rawBody(req)) || "{}");
  } catch {
    return {};
  }
}

export function send(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

export function page(res, status, html) {
  res.statusCode = status;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(html);
}

/** What each plan costs, in US cents. */
export const PRICES = {
  monthly: { unit_amount: 299, recurring: { interval: "month" }, nickname: "Monthly" },
  yearly: { unit_amount: 1500, recurring: { interval: "year" }, nickname: "Yearly" },
  lifetime: { unit_amount: 2000, nickname: "Lifetime" },
};

/**
 * The price for a plan, found by its lookup key. The first time a plan is bought in a Stripe account
 * that doesn't have it yet, it is made (with the AnyWhere Pro product), so the account owner never has
 * to run a script. Two first purchases at once can't make two: a lookup key is unique, so the loser of
 * that race just reads the winner's price.
 */
export async function priceFor(plan, client = stripe()) {
  const spec = PLANS[plan];
  if (!spec) return null;
  const find = async () =>
    (await client.prices.list({ lookup_keys: [spec.lookupKey], active: true, limit: 1 })).data[0]?.id ?? null;
  const found = await find();
  if (found) return found;
  try {
    const price = await client.prices.create({
      currency: "usd",
      lookup_key: spec.lookupKey,
      product: await productId(client),
      ...PRICES[plan],
    });
    return price.id;
  } catch (error) {
    const again = await find();
    if (again) return again;
    throw error;
  }
}

async function productId(client) {
  // A price for another plan already names the product.
  const lookupKeys = Object.values(PLANS).map((p) => p.lookupKey);
  const priced = (await client.prices.list({ lookup_keys: lookupKeys, limit: 3 })).data[0]?.product;
  if (priced) return typeof priced === "string" ? priced : priced.id;
  const products = await client.products.list({ active: true, limit: 100 });
  const existing = products.data.find((p) => p.metadata?.anywhere === "pro");
  if (existing) return existing.id;
  const made = await client.products.create({
    name: "AnyWhere Pro",
    description: "Change your iPhone's location on the iPhone alone: teleport, natural drives with stops, joystick.",
    metadata: { anywhere: "pro" },
  });
  return made.id;
}

/**
 * A refunded or disputed charge: if it paid for Lifetime, the customer loses it (the key stays, and
 * works again for any subscription they have or buy).
 */
export async function revokeLifetime(charge) {
  const customerId = typeof charge?.customer === "string" ? charge.customer : charge?.customer?.id;
  const intentId = typeof charge?.payment_intent === "string" ? charge.payment_intent : charge?.payment_intent?.id;
  if (!customerId || !intentId) return false;
  const intent = await stripe().paymentIntents.retrieve(intentId);
  if (intent.metadata?.anywhere_plan !== "lifetime") return false;
  // An empty string removes a metadata key.
  await stripe().customers.update(customerId, { metadata: { anywhere_lifetime: "" } });
  return true;
}

/**
 * Give the customer of a finished Checkout a license key: the webhook and the success page both call
 * this, in either order or at once, and get the same key. A lifetime purchase is marked on the customer.
 */
export async function ensureLicense(session) {
  const paid = session.status === "complete" && ["paid", "no_payment_required"].includes(session.payment_status);
  const customerId = typeof session.customer === "string" ? session.customer : session.customer?.id;
  if (!paid || !customerId) return null;
  const customer = await stripe().customers.retrieve(customerId);
  const lifetime = session.mode === "payment" && session.metadata?.anywhere_plan === "lifetime";
  // The same secret however many times, and from whichever call gets here first: it is derived from
  // the customer, so a webhook and the success page racing each other write the same value.
  const secret = customer.metadata?.anywhere_secret ?? secretFor(customerId, process.env.LICENSE_SIGNING_KEY);
  const changes = {};
  if (customer.metadata?.anywhere_secret !== secret) changes.anywhere_secret = secret;
  if (lifetime && customer.metadata?.anywhere_lifetime !== "true") changes.anywhere_lifetime = "true";
  if (Object.keys(changes).length) await stripe().customers.update(customerId, { metadata: changes });
  return makeKey(customerId, secret);
}
