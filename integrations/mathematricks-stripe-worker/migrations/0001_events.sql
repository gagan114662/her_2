CREATE TABLE IF NOT EXISTS stripe_events (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  livemode INTEGER NOT NULL,
  company_id TEXT,
  payment_link_id TEXT,
  checkout_session_id TEXT,
  payment_intent_id TEXT,
  amount_total INTEGER,
  currency TEXT,
  customer_email TEXT,
  raw_payload TEXT NOT NULL,
  received_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_stripe_events_received_at ON stripe_events(received_at);
CREATE INDEX IF NOT EXISTS idx_stripe_events_company_id ON stripe_events(company_id);
