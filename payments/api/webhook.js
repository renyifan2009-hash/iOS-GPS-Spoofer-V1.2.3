// Stripe → here when a Checkout finishes, so the key exists even if the buyer closes the page before the
// success page loads. Subscriptions need nothing stored: /api/license reads them from Stripe each time.
import { ensureLicense, rawBody, send, stripe } from "../lib/server.js";

export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST." });
  let event;
  try {
    event = stripe().webhooks.constructEvent(await rawBody(req), req.headers["stripe-signature"],
      process.env.STRIPE_WEBHOOK_SECRET);
  } catch (error) {
    return send(res, 400, { error: `Webhook signature didn't verify: ${error.message}` });
  }
  try {
    if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
      await ensureLicense(event.data.object);
    }
    send(res, 200, { received: true });
  } catch (error) {
    console.error("webhook", event.type, error);
    // Stripe retries a failed delivery; ensureLicense gives the same key each time.
    send(res, 500, { error: "Handler failed" });
  }
}
