-- Crystal ledger issuing server (D1). Apply: wrangler d1 execute pickuma-suhyeok-ledger --remote --file=schema.sql

-- Append-only, hash-chained server ledger (R21). Every balance change is a row; corrections are new rows.
-- hash = sha256(canonical JSON of every column but hash, keys sorted); see rowCanonical in ledger.js.
-- kind: register | entry (one per accepted device entry) | reserve (spend confirmation) | approve (genesis)
--       | revoke | correct (admin correction). amount = change to the device balance; reported = amount the
--       device (or admin) stated; dseq/dhash/dkind reference the device entry (-1/'' when none).
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
  last_spend_req  INTEGER NOT NULL           -- replay guard for spend requests
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
