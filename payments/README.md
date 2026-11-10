# AnyWhere Pro payments

The iPhone app is sideloaded, so it can't use App Store purchases. Pro is sold with **Stripe Checkout**
in Safari instead:

| Plan | Price | Stripe |
|---|---|---|
| Monthly | $2.99 a month | subscription, lookup key `anywhere_monthly` |
| Yearly | $15 a year | subscription, lookup key `anywhere_yearly` |
| Lifetime | $20 once | one-time payment, lookup key `anywhere_lifetime` |

New installs get a 3-day free trial (counted on the iPhone, kept in the Keychain). Pro is needed to
start a location in **This iPhone** mode. The Mac remote stays free, because the Mac app is free.

## How it works

1. The app asks `POST /api/checkout {"plan": "yearly"}` for a Checkout page and opens it in Safari.
2. After paying, Stripe sends the buyer to `/api/success`. That page shows a **license key**
   (`aw_<customer>_<secret>`) and opens `anywhere://activate?key=…`, which turns Pro on in the app.
3. The app checks the key with `POST /api/license`. The server reads the plan straight from Stripe and
   answers with that plan **signed with an Ed25519 key**. The app has the public half built in, so it can
   trust a saved answer offline for 7 days. It asks again once a day.
4. **Settings ▸ Manage Subscription** opens Stripe's customer portal (`POST /api/portal`) to change the
   card, switch plan or cancel.

There is no database. Stripe is the record. The key's secret lives in the Stripe customer's metadata
(`anywhere_secret`), and a lifetime purchase is marked with `anywhere_lifetime`. The webhook
(`/api/webhook`) only makes sure the key exists even if the buyer closes the success page early. The key
comes from an HMAC of the customer ID, so the webhook and the success page always agree on it.

## Set it up

You need a Stripe account and a Vercel account. Start in Stripe's **test mode**.

```bash
cd payments
npm install
npm test
```

1. **Signing keys.** This prints a secret for the server and a public key for the app:

   ```bash
   npm run keys
   ```

2. **Products and prices.** This creates the three prices above. It is safe to run again.

   ```bash
   STRIPE_SECRET_KEY=sk_test_... npm run setup-stripe
   ```

3. **Deploy** the `payments` folder to Vercel, with these environment variables:

   | Variable | Value |
   |---|---|
   | `STRIPE_SECRET_KEY` | `sk_test_…` (later `sk_live_…`) |
   | `LICENSE_SIGNING_KEY` | from step 1 (secret) |
   | `STRIPE_WEBHOOK_SECRET` | from step 4 |
   | `PUBLIC_URL` | the deployment's address, for example `https://anywhere-pay.vercel.app` |

   ```bash
   vercel --cwd payments
   ```

4. **Webhook.** In Stripe go to **Developers ▸ Webhooks ▸ Add endpoint** and use
   `https://<your deployment>/api/webhook` with the events `checkout.session.completed`,
   `checkout.session.async_payment_succeeded`, `charge.refunded` and `charge.dispute.created` (the last
   two take Lifetime away again after a full refund or a chargeback). Copy its signing secret into `STRIPE_WEBHOOK_SECRET`,
   then redeploy.

5. **Customer portal.** In Stripe go to **Settings ▸ Billing ▸ Customer portal**, turn it on, and allow
   cancelling and switching between Monthly and Yearly.

6. **The app.** In `iPhoneRemote/project.yml` set:

   ```yaml
   AW_PAYMENTS_SERVER: "https://<your deployment>"
   AW_PAYMENTS_PUBLIC_KEY: "<from step 1>"
   ```

   Then build the app again. While these two settings are empty, payments are off and everything is free.

7. **Test** a purchase with the card `4242 4242 4242 4242` (any future date, any CVC). The success page
   should open AnyWhere, and Settings should show "Pro · Yearly · renews …".

**Going live:** switch to `sk_live_…`, run `setup-stripe` again with the live key, make a live webhook,
and update `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` on Vercel. The signing keys stay the same.

## Endpoints

| Route | What it does |
|---|---|
| `POST /api/checkout` | `{plan}` → `{url}` (a Stripe Checkout page) |
| `GET /api/success?session_id=` | shows the license key and opens the app |
| `POST /api/license` | `{key}` → `{payload, signature}` (signed plan) |
| `POST /api/portal` | `{key}` → `{url}` (Stripe customer portal) |
| `POST /api/webhook` | Stripe events; makes sure the key exists |
| `GET /api/cancel`, `GET /api/done` | short pages to come back to the app |
