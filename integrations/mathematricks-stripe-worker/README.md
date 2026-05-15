# Mathematricks Stripe Worker

Production Stripe webhook receiver for the Mathematricks Starter payment link.

The Worker runs on Cloudflare, verifies Stripe webhook signatures, stores
accepted checkout completion events in D1, and exposes a token-protected event
readback endpoint for operational checks.

## Production Deployment

- Worker: `mathematricks-stripe-webhook`
- URL: `https://mathematricks-stripe-webhook.gagan-455.workers.dev`
- Webhook path: `/webhooks/stripe`
- Health path: `/health`
- D1 database: `mathematricks_stripe_events`
- Expected company id: `4731311e`
- Stripe event: `checkout.session.completed`
- Live payment link: `https://buy.stripe.com/14AdRa9RteGXeq7aF21kA00`

## Required Secrets

Set these with `wrangler secret put`; do not commit their values.

- `STRIPE_WEBHOOK_SECRET`: signing secret from the live Stripe webhook endpoint.
- `ADMIN_READ_TOKEN`: token required by `GET /events?token=...`.

## Deploy

```sh
npm install
npx wrangler d1 migrations apply mathematricks_stripe_events --remote
npx wrangler deploy
```

## Verify

```sh
curl -i https://mathematricks-stripe-webhook.gagan-455.workers.dev/health
```

Expected response:

```json
{"ok":true,"service":"mathematricks-stripe-webhook"}
```

The production endpoint was verified with a Stripe-signature-compatible
`checkout.session.completed` probe and stored the event in D1.
