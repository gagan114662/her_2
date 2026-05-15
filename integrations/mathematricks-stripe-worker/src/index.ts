export interface Env {
  DB: D1Database;
  STRIPE_WEBHOOK_SECRET: string;
  ADMIN_READ_TOKEN?: string;
  EXPECTED_COMPANY_ID?: string;
}

type StripeEvent = {
  id?: string;
  type?: string;
  livemode?: boolean;
  data?: {
    object?: {
      id?: string;
      object?: string;
      amount_total?: number;
      currency?: string;
      payment_intent?: string;
      payment_link?: string;
      customer_details?: { email?: string };
      customer_email?: string;
      metadata?: Record<string, string | undefined>;
    };
  };
};

const encoder = new TextEncoder();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "mathematricks-stripe-webhook" });
    }

    if (request.method === "GET" && url.pathname === "/events") {
      return readEvents(request, env);
    }

    if (request.method === "POST" && url.pathname === "/webhooks/stripe") {
      return handleStripeWebhook(request, env);
    }

    return json({ ok: false, error: "not_found" }, 404);
  }
};

async function handleStripeWebhook(request: Request, env: Env): Promise<Response> {
  if (!env.STRIPE_WEBHOOK_SECRET) {
    return json({ ok: false, error: "webhook_secret_missing" }, 500);
  }

  const signatureHeader = request.headers.get("stripe-signature") ?? "";
  const rawPayload = await request.text();
  const verified = await verifyStripeSignature(rawPayload, signatureHeader, env.STRIPE_WEBHOOK_SECRET);
  if (!verified.ok) {
    return json({ ok: false, error: verified.error }, verified.status);
  }

  let event: StripeEvent;
  try {
    event = JSON.parse(rawPayload) as StripeEvent;
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const eventID = clean(event.id);
  const eventType = clean(event.type);
  if (!eventID || !eventType) {
    return json({ ok: false, error: "missing_event_id_or_type" }, 400);
  }

  if (eventType !== "checkout.session.completed") {
    return json({ ok: true, ignored: true, event_id: eventID, event_type: eventType });
  }

  const session = event.data?.object ?? {};
  const companyID = clean(session.metadata?.company_id);
  if (env.EXPECTED_COMPANY_ID && companyID && companyID !== env.EXPECTED_COMPANY_ID) {
    return json({ ok: false, error: "company_id_mismatch" }, 400);
  }

  await env.DB.prepare(
    `INSERT OR IGNORE INTO stripe_events (
      event_id, event_type, livemode, company_id, payment_link_id,
      checkout_session_id, payment_intent_id, amount_total, currency,
      customer_email, raw_payload, received_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(
      eventID,
      eventType,
      event.livemode ? 1 : 0,
      companyID,
      clean(session.payment_link),
      clean(session.id),
      clean(session.payment_intent),
      Number.isFinite(session.amount_total) ? session.amount_total : null,
      clean(session.currency),
      clean(session.customer_details?.email) || clean(session.customer_email),
      rawPayload,
      new Date().toISOString()
    )
    .run();

  return json({
    ok: true,
    event_id: eventID,
    event_type: eventType,
    company_id: companyID,
    amount_total: session.amount_total ?? null,
    currency: session.currency ?? null
  });
}

async function readEvents(request: Request, env: Env): Promise<Response> {
  const token = new URL(request.url).searchParams.get("token") ?? "";
  if (!env.ADMIN_READ_TOKEN || token !== env.ADMIN_READ_TOKEN) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const { results } = await env.DB.prepare(
    `SELECT event_id, event_type, livemode, company_id, payment_link_id,
      checkout_session_id, payment_intent_id, amount_total, currency,
      customer_email, received_at
     FROM stripe_events
     ORDER BY received_at DESC
     LIMIT 50`
  ).all();

  return json({ ok: true, events: results ?? [] });
}

async function verifyStripeSignature(
  payload: string,
  header: string,
  secret: string
): Promise<{ ok: true } | { ok: false; error: string; status: number }> {
  const parts = new Map<string, string[]>();
  for (const piece of header.split(",")) {
    const [key, value] = piece.split("=", 2);
    if (!key || !value) continue;
    const values = parts.get(key) ?? [];
    values.push(value);
    parts.set(key, values);
  }

  const timestamp = parts.get("t")?.[0];
  const signatures = parts.get("v1") ?? [];
  if (!timestamp || signatures.length === 0) {
    return { ok: false, error: "signature_header_malformed", status: 400 };
  }

  const timestampNumber = Number(timestamp);
  if (!Number.isFinite(timestampNumber)) {
    return { ok: false, error: "signature_timestamp_invalid", status: 400 };
  }

  const ageSeconds = Math.abs(Date.now() / 1000 - timestampNumber);
  if (ageSeconds > 300) {
    return { ok: false, error: "signature_timestamp_outside_tolerance", status: 400 };
  }

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signedPayload = `${timestamp}.${payload}`;
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(signedPayload));
  const expected = hex(new Uint8Array(digest));

  if (!signatures.some((signature) => timingSafeEqual(signature, expected))) {
    return { ok: false, error: "signature_mismatch", status: 400 };
  }

  return { ok: true };
}

function clean(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let index = 0; index < a.length; index += 1) {
    diff |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return diff === 0;
}
