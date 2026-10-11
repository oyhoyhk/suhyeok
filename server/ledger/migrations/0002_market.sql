-- Market (U3/U4/U7) for a database created from the pre-market schema.sql. Apply ONCE:
--   wrangler d1 execute pickuma-suhyeok-ledger --remote --file=migrations/0002_market.sql
-- The ALTERs are not idempotent (SQLite has no ADD COLUMN IF NOT EXISTS); the CREATEs are.
-- The result matches a fresh schema.sql (test/market.test.js checks this).
ALTER TABLE devices ADD COLUMN pending_income INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN last_market_req INTEGER NOT NULL DEFAULT 0;

-- Character market (docs/plans/2026-10-11-002-feat-asset-market-plan.md). Mutable status lives here; every
-- status change is also a 'moderate' ledger row, so the history is reconstructible from the ledger alone.
-- status: draft -> pending -> approved | rejected; approved -> delisted; draft -> withdrawn.
CREATE TABLE IF NOT EXISTS listings (
  id          TEXT    PRIMARY KEY,         -- uuid
  seller      TEXT    NOT NULL,            -- device id
  kind        TEXT    NOT NULL,            -- 'character' (maps later)
  name        TEXT    NOT NULL,            -- manifest name
  description TEXT    NOT NULL,
  alias       TEXT    NOT NULL,            -- seller alias chosen at draft time ('' = none)
  price       INTEGER NOT NULL,
  status      TEXT    NOT NULL CHECK (status IN ('draft', 'pending', 'approved', 'rejected', 'delisted', 'withdrawn')),
  reason      TEXT    NOT NULL,            -- reject / delist reason ('' otherwise)
  manifest    TEXT    NOT NULL,            -- manifest.json exactly as uploaded
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS listings_status ON listings(status);
CREATE INDEX IF NOT EXISTS listings_seller ON listings(seller);
CREATE TRIGGER IF NOT EXISTS listings_fixed BEFORE UPDATE OF id, seller, kind, name, price, manifest, created_at ON listings
BEGIN SELECT RAISE(ABORT, 'listing contents are fixed'); END;

-- Uploaded pack files. The R2 key is always assets/<listing_id>/<sha256>, never derived from the request path.
CREATE TABLE IF NOT EXISTS listing_files (
  listing_id TEXT    NOT NULL,
  path       TEXT    NOT NULL,             -- pack path, validated by assets.js classifyPath
  sha256     TEXT    NOT NULL,
  bytes      INTEGER NOT NULL,
  PRIMARY KEY (listing_id, path)
);

-- Purchases. server_seq = the buyer's reserve row; body/sig = the signed purchase receipt (idempotent retry).
CREATE TABLE IF NOT EXISTS owners (
  listing_id TEXT    NOT NULL,
  device     TEXT    NOT NULL,
  server_seq INTEGER NOT NULL,
  price      INTEGER NOT NULL,
  req_time   INTEGER NOT NULL,
  body       TEXT    NOT NULL,
  sig        TEXT    NOT NULL,
  PRIMARY KEY (listing_id, device)
);
CREATE INDEX IF NOT EXISTS owners_device ON owners(device);

-- Short-lived download tokens (random, 10 minutes). Expired rows are pruned when a new token is issued.
CREATE TABLE IF NOT EXISTS download_tokens (
  token      TEXT    PRIMARY KEY,
  device     TEXT    NOT NULL,
  listing_id TEXT    NOT NULL,
  expires_at INTEGER NOT NULL
);
