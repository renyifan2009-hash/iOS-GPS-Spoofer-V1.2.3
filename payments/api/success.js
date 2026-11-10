// Where Stripe Checkout lands after paying: shows the license key and opens AnyWhere with it.
import { messagePage, pendingPage, successPage } from "../lib/pages.js";
import { ensureLicense, page, stripe } from "../lib/server.js";

export default async function handler(req, res) {
  const id = new URL(req.url, "https://local").searchParams.get("session_id") ?? "";
  if (!/^cs_[A-Za-z0-9_]+$/.test(id)) return page(res, 400, messagePage("Link not recognised", "Open AnyWhere and try again."));
  try {
    const session = await stripe().checkout.sessions.retrieve(id);
    const key = await ensureLicense(session);
    if (!key) return page(res, 202, pendingPage());
    page(res, 200, successPage(key));
  } catch (error) {
    console.error("success", error);
    page(res, 502, messagePage("Something went wrong", "Your payment went through if Stripe said so. Reload this page in a minute to see your key."));
  }
}
