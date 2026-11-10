# Turning on payments (for the account owner)

This is for the person whose Stripe account gets the money. No coding is needed: it's about 20 minutes
of clicking. You need a computer with a web browser.

AnyWhere Pro costs **$2.99 a month, $15 a year, or $20 once**. New users get a 3-day free trial. Stripe
handles the cards. The money goes to the bank account you add in Stripe.

> **Do this after the `iphone-app-polish-and-payments` branch is merged into `main`.** Vercel builds
> from `main`, and the payment server only exists on that branch until then.

## What you get from the developer

One secret value called **`LICENSE_SIGNING_KEY`**. The app uses it to know a license is real. Get it
privately, for example by AirDrop or in person. Don't put it in a group chat, an email, or the GitHub
repo.

## 1. Make the Stripe account

1. Go to [dashboard.stripe.com/register](https://dashboard.stripe.com/register) and sign up.
2. **If you're under 18:** Stripe lets you sign up from age 13. Before the account can take payments or
   pay out to a bank, a parent or legal guardian has to be added as the account owner
   ([Stripe's rule](https://support.stripe.com/questions/age-requirement-to-create-a-stripe-account)).
3. Stay in **test mode** for now (the switch is in the top bar). Nothing real is charged in test mode.
4. Open **Developers ▸ API keys**. Copy the **Secret key**, which starts with `sk_test_`. You'll paste it
   into Vercel in step 2. It's a password for your money, so don't send it to anyone, including the
   developer.

## 2. Put the server online (Vercel, free)

1. Go to [vercel.com](https://vercel.com) and sign up **with GitHub**. Use the account that owns the
   AnyWhere repo.
2. Click **Add New ▸ Project** and import **iOS-GPS-Spoofer-V1.2.3**.
3. Next to **Root Directory**, click **Edit** and pick **`payments`**. Leave Framework Preset as **Other**.
4. Open **Environment Variables** and add:

   | Name | Value |
   |---|---|
   | `STRIPE_SECRET_KEY` | your `sk_test_…` key from step 1 |
   | `LICENSE_SIGNING_KEY` | the value the developer gave you |

5. Click **Deploy**. When it's done, Vercel shows the address, like `https://anywhere-pay.vercel.app`.
   **Send that address to the developer.** It isn't secret.
6. Go back to **Settings ▸ Environment Variables** and add `PUBLIC_URL` set to that address.

## 3. Tell Stripe about the server (webhook)

1. In Stripe, open **Developers ▸ Webhooks** and add an endpoint.
2. Endpoint URL: your address followed by `/api/webhook`, for example
   `https://anywhere-pay.vercel.app/api/webhook`.
3. Choose these events:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
   - `charge.refunded`
   - `charge.dispute.created`
4. Save. Copy the **Signing secret**, which starts with `whsec_`.
5. In Vercel, add the environment variable `STRIPE_WEBHOOK_SECRET` with that value.
6. Open **Deployments** in Vercel, click **⋯** on the newest one, and choose **Redeploy**.

## 4. Let people manage their subscription

In Stripe, open **Settings ▸ Billing ▸ Customer portal** and turn it on. Allow customers to cancel and to
switch between Monthly and Yearly. This is the page people reach from **Manage Subscription** in the app.

Optional: in **Settings ▸ Customer emails**, turn on receipts for successful payments.

## 5. Try a purchase (test mode)

Once the developer has a build with your address, open the app and go to **Settings ▸ Choose a Plan**.
Pay with the test card `4242 4242 4242 4242` (any future expiry date, any CVC). You should land on a page
that says "You're in." with a license key, and the app should show Pro.

You don't have to create the prices. The server makes them in Stripe the first time each plan is bought
(the product is named "AnyWhere Pro").

## 6. Go live (real money)

1. In Stripe, finish **Activate account**: your details and a bank account. If you're under 18, this is
   where the parent or guardian comes in.
2. Switch Stripe out of test mode and copy the **live** secret key (`sk_live_…`).
3. Make a live webhook, the same as step 3, and copy its new `whsec_…` secret.
4. In Vercel, replace `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` with the live values, then redeploy.
   Keep `LICENSE_SIGNING_KEY` the same: licenses already given out keep working.

That's it. Payouts arrive in the bank account on Stripe's schedule.
