// POST {"plan": "monthly" | "yearly" | "lifetime"} → {"url": Stripe Checkout}
import { checkoutParams } from "../lib/license.js";
import { baseURL, jsonBody, priceFor, send, stripe } from "../lib/server.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST." });
  const { plan } = await jsonBody(req);
  try {
    const params = checkoutParams(plan, await priceFor(plan), baseURL(req));
    if (!params) return send(res, 400, { error: "Pick monthly, yearly or lifetime." });
    const session = await stripe().checkout.sessions.create(params);
    send(res, 200, { url: session.url });
  } catch (error) {
    console.error("checkout", error);
    send(res, 502, { error: "Couldn't start the checkout. Try again in a minute." });
  }
}
