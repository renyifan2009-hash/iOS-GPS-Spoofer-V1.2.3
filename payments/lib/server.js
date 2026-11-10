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

/** The price for a plan, found by its lookup key (made by scripts/setup-stripe.mjs). */
export async function priceFor(plan) {
  const spec = PLANS[plan];
  if (!spec) return null;
  const prices = await stripe().prices.list({ lookup_keys: [spec.lookupKey], active: true, limit: 1 });
  return prices.data[0]?.id ?? null;
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
