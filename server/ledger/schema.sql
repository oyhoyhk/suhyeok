-- Crystal ledger issuing server (D1). Full schema for a fresh database:
--   wrangler d1 execute pickuma-suhyeok-ledger --remote --file=schema.sql
-- A database created before a change gets the matching file in migrations/ instead (0002_market.sql: market).

-- Append-only, hash-chained server ledger (R21). Every balance change is a row; corrections are new rows.
-- hash = sha256(canonical JSON of every column but hash, keys sorted); see rowCanonical in ledger.js.
-- kind: register | entry (one per accepted device entry) | reserve (spend confirmation) | approve (genesis)
--       | revoke | correct (admin correction)
--       | moderate (market listing state change: ref '<listingId>:<state>', amount 0, device = seller,
--                   note = reason for reject/delist, reported = price on the 'draft' row)
--       | sale (seller credit for a purchase: ref 'market:<listingId>', amount = seller share, reported = price)
--       | burn (the rest of the price: device '', ref 'market:<listingId>', note 'buyer:<id>', amount = burned).
--       A purchase is one reserve (buyer -price) + sale + burn: the three amounts sum to zero.
--       amount = change to the device balance; reported = amount the device (or admin) stated; dseq/dhash/dkind
--       reference the device entry (-1/'' when none).
CREATE TABLE IF NOT EXISTS ledger (
  seq      INTEGER PRIMARY KEY,
  time     INTEGER NOT NULL,
  device   TEXT    NOT NULL,
  kind     TEXT    NOT NULL,
  amount   INTEGER NOT NULL,
  dseq     INTEGER NOT NULL,
  dhash    TEXT    NOT NULL,
  dkind    TEXT    NOT NULL,
  reported INTEGER NOT NULL,
  ref      TEXT    NOT NULL,
  note     TEXT    NOT NULL,
  prev     TEXT    NOT NULL,
  hash     TEXT    NOT NULL UNIQUE
);
CREATE UNIQUE INDEX IF NOT EXISTS ledger_device_entry ON ledger(device, dseq) WHERE kind = 'entry';
CREATE INDEX IF NOT EXISTS ledger_device ON ledger(device);
-- Defence in depth only: an operator can drop these, which the hash chain and the anchoring then expose.
CREATE TRIGGER IF NOT EXISTS ledger_no_update BEFORE UPDATE ON ledger BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS ledger_no_delete BEFORE DELETE ON ledger BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;

-- Per-device sync state; balance is a cache of SUM(ledger.amount) for the device (checked by /admin/verify).
CREATE TABLE IF NOT EXISTS devices (
  id              TEXT    PRIMARY KEY,
  key             TEXT    NOT NULL UNIQUE,   -- base64 X9.63 P-256 public key
  registered_at   INTEGER NOT NULL,
  revoked_at      INTEGER,
  last_seq        INTEGER NOT NULL,          -- last acknowledged device seq, -1 before the first sync
  last_hash       TEXT    NOT NULL,
  last_time       INTEGER,
  balance         INTEGER NOT NULL,
  pending_clamp   INTEGER NOT NULL,          -- clamped earnings not yet answered by a device adjust entry
  pending_genesis INTEGER NOT NULL,
  last_spend_req  INTEGER NOT NULL,          -- replay guard for spend requests
  pending_income  INTEGER NOT NULL DEFAULT 0,  -- sale proceeds credited but not yet booked by a device income entry
  last_market_req INTEGER NOT NULL DEFAULT 0   -- replay guard for state-changing market requests (draft, submit, withdraw, buy)
);

CREATE TABLE IF NOT EXISTS codes (
  code       TEXT    PRIMARY KEY,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at    INTEGER,
  device     TEXT
);

-- Signed sync receipts, keyed by the last device seq of the batch (idempotent resend).
CREATE TABLE IF NOT EXISTS receipts (
  device TEXT    NOT NULL,
  dseq   INTEGER NOT NULL,
  body   TEXT    NOT NULL,
  sig    TEXT    NOT NULL,
  PRIMARY KEY (device, dseq)
);

-- Spend confirmations; consumed_seq = server seq of the synced spend entry that used it.
CREATE TABLE IF NOT EXISTS reservations (
  server_seq   INTEGER PRIMARY KEY,
  device       TEXT    NOT NULL,
  item         TEXT    NOT NULL,
  amount       INTEGER NOT NULL,
  req_time     INTEGER NOT NULL,
  consumed_seq INTEGER,
  body         TEXT    NOT NULL,
  sig          TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS reservations_open ON reservations(device, item) WHERE consumed_seq IS NULL;

-- Genesis entries awaiting admin approval (R20).
CREATE TABLE IF NOT EXISTS genesis (
  server_seq   INTEGER PRIMARY KEY,
  device       TEXT    NOT NULL,
  dseq         INTEGER NOT NULL,
  amount       INTEGER NOT NULL,
  approved_seq INTEGER
);

-- OpenTimestamps anchors of the ledger head (R25-R27). Rows are never deleted and the anchored seq/hash/time
-- never change; only the proof grows (pending -> confirmed) when a calendar returns the Bitcoin attestation.
-- proof = base64 of the complete .ots file whose file digest is `hash`.
CREATE TABLE IF NOT EXISTS anchors (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  seq          INTEGER NOT NULL,
  hash         TEXT    NOT NULL,
  submitted_at INTEGER NOT NULL,
  calendars    INTEGER NOT NULL,   -- calendars that accepted the digest
  status       TEXT    NOT NULL CHECK (status IN ('pending', 'confirmed')),
  height       INTEGER,            -- lowest Bitcoin block height attested, once confirmed
  upgraded_at  INTEGER,
  proof        TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS anchors_pending ON anchors(id) WHERE status = 'pending';
CREATE TRIGGER IF NOT EXISTS anchors_no_delete BEFORE DELETE ON anchors BEGIN SELECT RAISE(ABORT, 'anchors are append-only'); END;
CREATE TRIGGER IF NOT EXISTS anchors_fixed BEFORE UPDATE OF seq, hash, submitted_at ON anchors BEGIN SELECT RAISE(ABORT, 'anchored values are fixed'); END;
CREATE TRIGGER IF NOT EXISTS anchors_no_unconfirm BEFORE UPDATE ON anchors WHEN OLD.status = 'confirmed' AND NEW.status <> 'confirmed'
BEGIN SELECT RAISE(ABORT, 'confirmed anchors stay confirmed'); END;

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
