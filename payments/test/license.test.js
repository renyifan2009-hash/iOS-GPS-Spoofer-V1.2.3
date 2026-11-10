import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import {
  OFFLINE_DAYS, checkoutParams, entitlement, escapeHTML, makeKey, makeSecret, makeSigningKeys, parseKey,
  secretFor, secretMatches, signLicense,
} from "../lib/license.js";
import { successPage } from "../lib/pages.js";

const NOW = Date.UTC(2026, 10, 10);

test("a key names its customer and round-trips", () => {
  const secret = makeSecret(Buffer.alloc(10, 7));
  assert.match(secret, /^[A-Z2-7]{16}$/);
  const key = makeKey("cus_Pq9XyZ12ab", secret);
  assert.equal(key, `aw_Pq9XyZ12ab_${secret}`);
  assert.deepEqual(parseKey(` ${key} `), { customerId: "cus_Pq9XyZ12ab", secret });
});

test("the app's key pattern accepts what the server makes", () => {
  // Same pattern as LicenseStore.looksLikeKey in the iPhone app.
  const app = /^aw_[A-Za-z0-9]{6,40}_[A-Z2-7]{12,40}$/;
  for (let i = 0; i < 50; i++) assert.match(makeKey("cus_" + crypto.randomBytes(7).toString("hex"), makeSecret()), app);
});

test("anything else is not a key", () => {
  for (const bad of ["", "aw_", "aw_x_y", "cus_123", "aw_abc!def_AAAAAAAAAAAA", "aw_abcdef_aaaaaaaaaaaa", null, 42,
    "aw_abcdef_AAAAAAAAAAAA' OR '1"]) {
    assert.equal(parseKey(bad), null, String(bad));
  }
});

test("secrets compare exactly", () => {
  assert.equal(secretMatches("ABCDEFGHIJKLMNOP", "ABCDEFGHIJKLMNOP"), true);
  assert.equal(secretMatches("ABCDEFGHIJKLMNOP", "ABCDEFGHIJKLMNOQ"), false);
  assert.equal(secretMatches(undefined, "ABCDEFGHIJKLMNOP"), false);
  assert.equal(secretMatches("ABC", "ABCD"), false);
});

test("the secret for a customer is stable, so racing calls agree", () => {
  const { signingKey } = makeSigningKeys();
  assert.equal(secretFor("cus_A1", signingKey), secretFor("cus_A1", signingKey));
  assert.notEqual(secretFor("cus_A1", signingKey), secretFor("cus_A2", signingKey));
  assert.throws(() => secretFor("cus_A1", ""));
});

test("lifetime beats any subscription", () => {
  const answer = entitlement({ metadata: { anywhere_lifetime: "true" } }, [{ status: "canceled" }], "k", NOW);
  assert.equal(answer.plan, "lifetime");
  assert.equal(answer.status, "lifetime");
  assert.equal(answer.expiresAt, null);
  assert.equal(answer.validUntil - answer.issuedAt, OFFLINE_DAYS * 86400);
});

test("the best subscription wins, with its plan and period end", () => {
  const item = (lookup, end) => ({ data: [{ price: { lookup_key: lookup }, current_period_end: end }] });
  const subs = [
    { status: "canceled", items: item("anywhere_monthly", 100) },
    { status: "active", items: item("anywhere_yearly", 2_000_000_000) },
  ];
  const answer = entitlement({ metadata: {} }, subs, "k", NOW);
  assert.equal(answer.plan, "yearly");
  assert.equal(answer.status, "active");
  assert.equal(answer.expiresAt, 2_000_000_000);
  assert.equal(answer.endsAtPeriodEnd, undefined);
});

test("older API versions keep the period on the subscription", () => {
  const answer = entitlement({ metadata: {} }, [{ status: "active", current_period_end: 123, cancel_at_period_end: true,
    items: { data: [{ price: { lookup_key: "anywhere_monthly" } }] } }], "k", NOW);
  assert.equal(answer.expiresAt, 123);
  assert.equal(answer.endsAtPeriodEnd, true);
});

test("no purchase at all is status none", () => {
  assert.equal(entitlement({ metadata: {} }, [], "k", NOW).status, "none");
});

test("a signed answer verifies with the app's raw public key, and only unchanged", () => {
  const { signingKey, appPublicKey } = makeSigningKeys();
  const token = signLicense({ key: "k", plan: "yearly" }, signingKey);
  // Rebuild the public key the way CryptoKit's Curve25519 rawRepresentation does: 32 bytes.
  const raw = Buffer.from(appPublicKey, "base64");
  assert.equal(raw.length, 32);
  const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]);
  const publicKey = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
  const payload = Buffer.from(token.payload, "base64");
  assert.equal(crypto.verify(null, payload, publicKey, Buffer.from(token.signature, "base64")), true);
  const tampered = Buffer.from(JSON.stringify({ key: "k", plan: "lifetime" }));
  assert.equal(crypto.verify(null, tampered, publicKey, Buffer.from(token.signature, "base64")), false);
});

test("checkout: subscriptions for monthly and yearly, a payment that makes a customer for lifetime", () => {
  const monthly = checkoutParams("monthly", "price_m", "https://pay.example");
  assert.equal(monthly.mode, "subscription");
  assert.equal(monthly.subscription_data.metadata.anywhere_plan, "monthly");
  assert.match(monthly.success_url, /session_id=\{CHECKOUT_SESSION_ID\}$/);
  const lifetime = checkoutParams("lifetime", "price_l", "https://pay.example");
  assert.equal(lifetime.mode, "payment");
  assert.equal(lifetime.customer_creation, "always");
  assert.equal(lifetime.metadata.anywhere_plan, "lifetime");
  assert.equal(checkoutParams("forever", "price_x", "https://pay.example"), null);
  assert.equal(checkoutParams("yearly", null, "https://pay.example"), null);
});

test("the success page escapes the key and links back into the app", () => {
  const html = successPage("aw_abc123_<script>");
  assert.ok(!html.includes("<script>alert") && html.includes("aw_abc123_&lt;script&gt;"));
  assert.ok(html.includes("anywhere://activate?key=aw_abc123_%3Cscript%3E"));
  assert.equal(escapeHTML(`"'<>&`), "&quot;&#39;&lt;&gt;&amp;");
});
