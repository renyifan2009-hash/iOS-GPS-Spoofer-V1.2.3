// POST {"key": "aw_…"} → a signed answer the app trusts: {"payload": base64 JSON, "signature": base64}
// The payload says the plan, its status and when it ends, straight from Stripe.
import { entitlement, parseKey, secretMatches, signLicense } from "../lib/license.js";
import { jsonBody, send, stripe } from "../lib/server.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST." });
  const { key } = await jsonBody(req);
  const parsed = parseKey(key);
  if (!parsed) return send(res, 400, { error: "That isn't an AnyWhere license key." });
  if (!process.env.LICENSE_SIGNING_KEY) return send(res, 500, { error: "The payment server isn't set up yet." });
  try {
    let customer;
    try {
      customer = await stripe().customers.retrieve(parsed.customerId);
    } catch (error) {
      if (error?.statusCode === 404) return send(res, 404, { error: "No license with that key." });
      throw error;
    }
    if (customer.deleted || !secretMatches(customer.metadata?.anywhere_secret, parsed.secret)) {
      return send(res, 404, { error: "No license with that key." });
    }
    const subscriptions = await stripe().subscriptions.list({
      customer: customer.id, status: "all", limit: 20, expand: ["data.items.data.price"],
    });
    const answer = entitlement(customer, subscriptions.data, key.trim());
    send(res, 200, signLicense(answer, process.env.LICENSE_SIGNING_KEY));
  } catch (error) {
    console.error("license", error);
    send(res, 502, { error: "Couldn't check the license right now. Try again in a minute." });
  }
}
