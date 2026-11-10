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

The Stripe account owner follows **[OWNER-SETUP.md](OWNER-SETUP.md)**. It's click-by-click with no code,
and covers Stripe, deploying this folder to Vercel, the webhook and the customer portal. The developer's
part:

1. **Signing keys** are already made. The public half is `AW_PAYMENTS_PUBLIC_KEY` in
   `iPhoneRemote/project.yml`. The private half, `LICENSE_SIGNING_KEY`, is kept outside the repo and goes
   privately to the owner for Vercel. To start over, run `npm run keys` and update both.
2. **Prices** don't need setting up. The server makes the three prices (lookup keys above) in Stripe the
   first time each plan is bought. `npm run setup-stripe` makes them ahead of time if you want to see
   them first.
3. When the owner sends the deployment address, set it in `iPhoneRemote/project.yml`:

   ```yaml
   AW_PAYMENTS_SERVER: "https://<the deployment>"
   ```

   Then build the app again. While `AW_PAYMENTS_SERVER` is empty, payments are off and everything is free.

Server environment variables (set by the owner on Vercel):

| Variable | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_test_…`, later `sk_live_…` |
| `LICENSE_SIGNING_KEY` | the private signing key (secret) |
| `STRIPE_WEBHOOK_SECRET` | the webhook's `whsec_…` |
| `PUBLIC_URL` | the deployment's address |

Webhook events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`,
`charge.refunded`, `charge.dispute.created`. The last two take Lifetime away again after a full refund or
a chargeback.

Run the tests with `npm install && npm test`.

## Endpoints

| Route | What it does |
|---|---|
| `POST /api/checkout` | `{plan}` → `{url}` (a Stripe Checkout page) |
| `GET /api/success?session_id=` | shows the license key and opens the app |
| `POST /api/license` | `{key}` → `{payload, signature}` (signed plan) |
| `POST /api/portal` | `{key}` → `{url}` (Stripe customer portal) |
| `POST /api/webhook` | Stripe events; makes sure the key exists |
| `GET /api/cancel`, `GET /api/done` | short pages to come back to the app |
