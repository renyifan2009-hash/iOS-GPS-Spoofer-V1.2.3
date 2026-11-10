// License keys and the signed answers the iPhone app trusts. No Stripe calls here, so it can be tested
// on its own.
//
// A key names its Stripe customer and carries a secret that only that customer's metadata holds:
//   aw_<customer id without "cus_">_<16 base32 letters>
// so checking one is a direct (strongly consistent) customer lookup, never a search.
import crypto from "node:crypto";

export const PLANS = {
  monthly: { lookupKey: "anywhere_monthly", mode: "subscription" },
  yearly: { lookupKey: "anywhere_yearly", mode: "subscription" },
  lifetime: { lookupKey: "anywhere_lifetime", mode: "payment" },
};

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const KEY_PATTERN = /^aw_([A-Za-z0-9]{6,40})_([A-Z2-7]{12,40})$/;

/** How long the app may trust an answer without asking again (offline use). */
export const OFFLINE_DAYS = 7;

export function makeSecret(bytes = crypto.randomBytes(10)) {
  // 10 bytes = 80 bits = 16 base32 letters.
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

/** The secret for a customer: an HMAC of its id under the server's signing key, so it is stable. */
export function secretFor(customerId, serverKey) {
  if (!serverKey) throw new Error("LICENSE_SIGNING_KEY isn't set");
  return makeSecret(crypto.createHmac("sha256", serverKey).update(customerId).digest().subarray(0, 10));
}

export function makeKey(customerId, secret) {
  if (!/^cus_[A-Za-z0-9]+$/.test(customerId)) throw new Error("not a Stripe customer id");
  return `aw_${customerId.slice(4)}_${secret}`;
}

/** { customerId, secret } for a well-formed key, else null. */
export function parseKey(key) {
  const match = typeof key === "string" ? KEY_PATTERN.exec(key.trim()) : null;
  return match ? { customerId: `cus_${match[1]}`, secret: match[2] } : null;
}

/** Does the customer's stored secret match the key's? Constant time. */
export function secretMatches(stored, given) {
  if (typeof stored !== "string" || typeof given !== "string" || stored.length !== given.length) return false;
  return crypto.timingSafeEqual(Buffer.from(stored), Buffer.from(given));
}

function periodEnd(subscription) {
  // Newer Stripe API versions keep the period on the subscription item.
  return subscription.items?.data?.[0]?.current_period_end ?? subscription.current_period_end ?? null;
}

function planOf(subscription) {
  const lookup = subscription.items?.data?.[0]?.price?.lookup_key;
  return Object.keys(PLANS).find((plan) => PLANS[plan].lookupKey === lookup) ?? "monthly";
}

/**
 * What a customer is owed, from Stripe's own records (Stripe is the source of truth):
 * a lifetime purchase, else their best subscription.
 */
export function entitlement(customer, subscriptions, key, now = Date.now()) {
  const issuedAt = Math.floor(now / 1000);
  const validUntil = issuedAt + OFFLINE_DAYS * 24 * 3600;
  if (customer?.metadata?.anywhere_lifetime === "true") {
    return { key, plan: "lifetime", status: "lifetime", expiresAt: null, issuedAt, validUntil };
  }
  const rank = { active: 0, trialing: 1, past_due: 2, unpaid: 3, canceled: 4, incomplete: 5, incomplete_expired: 6 };
  const best = [...(subscriptions ?? [])].sort((a, b) =>
    (rank[a.status] ?? 9) - (rank[b.status] ?? 9) || (periodEnd(b) ?? 0) - (periodEnd(a) ?? 0))[0];
  if (!best) return { key, plan: "monthly", status: "none", expiresAt: null, issuedAt, validUntil };
  const answer = { key, plan: planOf(best), status: best.status, expiresAt: periodEnd(best), issuedAt, validUntil };
  // Cancelled "at period end": still active until then, and the app says "ends" rather than "renews".
  if (best.cancel_at_period_end) answer.endsAtPeriodEnd = true;
  return answer;
}

/**
 * The answer the app verifies: the payload as base64 JSON and an Ed25519 signature of exactly those
 * bytes. `signingKey` is a PEM private key, or that PEM in base64 (easier to keep in an env var).
 */
export function signLicense(payload, signingKey) {
  const pem = signingKey.includes("BEGIN") ? signingKey : Buffer.from(signingKey, "base64").toString("utf8");
  const bytes = Buffer.from(JSON.stringify(payload), "utf8");
  const signature = crypto.sign(null, bytes, crypto.createPrivateKey(pem));
  return { payload: bytes.toString("base64"), signature: signature.toString("base64") };
}

/** A new signing key pair: the server's private key (base64 PEM) and the app's raw public key (base64). */
export function makeSigningKeys() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const pem = privateKey.export({ type: "pkcs8", format: "pem" });
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url");
  return { signingKey: Buffer.from(pem).toString("base64"), appPublicKey: raw.toString("base64") };
}

/** Checkout Session parameters for a plan, or null for a plan that doesn't exist. */
export function checkoutParams(plan, priceId, baseURL) {
  const spec = PLANS[plan];
  if (!spec || !priceId) return null;
  const params = {
    mode: spec.mode,
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: `${baseURL}/api/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${baseURL}/api/cancel`,
    allow_promotion_codes: true,
    metadata: { anywhere_plan: plan },
  };
  if (spec.mode === "payment") {
    params.customer_creation = "always";
    params.payment_intent_data = { metadata: { anywhere_plan: plan } };
  } else {
    params.subscription_data = { metadata: { anywhere_plan: plan } };
  }
  return params;
}

export function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
