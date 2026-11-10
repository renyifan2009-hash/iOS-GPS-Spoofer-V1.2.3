// POST {"key": "aw_…"} → {"url": Stripe's billing portal} to change the card, switch plan or cancel.
import { parseKey, secretMatches } from "../lib/license.js";
import { baseURL, jsonBody, send, stripe } from "../lib/server.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST." });
  const parsed = parseKey((await jsonBody(req)).key);
  if (!parsed) return send(res, 400, { error: "That isn't an AnyWhere license key." });
  try {
    const customer = await stripe().customers.retrieve(parsed.customerId).catch(() => null);
    if (!customer || customer.deleted || !secretMatches(customer.metadata?.anywhere_secret, parsed.secret)) {
      return send(res, 404, { error: "No license with that key." });
    }
    const session = await stripe().billingPortal.sessions.create({
      customer: customer.id, return_url: `${baseURL(req)}/api/done`,
    });
    send(res, 200, { url: session.url });
  } catch (error) {
    console.error("portal", error);
    send(res, 502, { error: "Couldn't open subscription settings. Try again in a minute." });
  }
}
