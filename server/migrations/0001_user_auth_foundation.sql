-- 0001_user_auth_foundation
--
-- The account foundation for pulsecue-api: who a user is, which provider
-- identities are linked to them, and which sessions are currently valid.
--
-- Deliberately absent:
--   * no provider tokens. Apple/Google credentials are verified server-side
--     (PR 2 / PR 3) and not retained here. The one exception is planned for
--     Apple revocation and is NOT added yet — it needs the real Apple flow
--     designed first.
--   * no synced workout data. The first sync slice (workout sessions and
--     step results) lands in its own migration once this foundation exists.
--
-- Timestamps are unix epoch seconds (INTEGER, UTC). D1 has no native date
-- type, and integers sort and compare without any locale or format risk.

PRAGMA foreign_keys = ON;

-- A PulseCue user. The only owner identity in the system: everything that
-- ever syncs will hang off `users.id`, never off a provider's identifier.
CREATE TABLE users (
  id           TEXT PRIMARY KEY NOT NULL,
  -- 'active'   — normal.
  -- 'deleting' — deletion requested; sessions are already revoked and the
  --              rows are purged by a follow-up job (PR 7).
  state        TEXT NOT NULL DEFAULT 'active'
                 CHECK (state IN ('active', 'deleting')),
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  -- Set when deletion is requested. Soft delete first so an accidental
  -- request is recoverable and so revocation can be retried.
  deleted_at   INTEGER
);

-- A provider identity linked to a user. A user may link more than one
-- (Apple *and* Google), which is why this is a separate table rather than
-- columns on `users`.
--
-- `subject` is the provider's stable subject claim from a *server-verified*
-- token — `sub` from Apple's identity token or Google's ID token. A client
-- supplied identifier is never written here.
--
-- Identities are never merged by email. Apple's private relay means the
-- address can differ or change, and matching on it would let anyone who
-- controls an address claim an existing account. Linking a second provider
-- is only ever an explicit action taken while already signed in.
CREATE TABLE auth_identities (
  id             TEXT PRIMARY KEY NOT NULL,
  user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider       TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject        TEXT NOT NULL,
  -- Display only, and only when the provider chose to give it. Never used
  -- to find or merge an account.
  email          TEXT,
  email_verified INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1)),
  created_at     INTEGER NOT NULL,
  last_seen_at   INTEGER NOT NULL,
  -- One account per provider subject, globally.
  UNIQUE (provider, subject)
);

CREATE INDEX idx_auth_identities_user ON auth_identities (user_id);

-- Display metadata. Split from `users` so account lifecycle columns stay
-- separate from anything the user can edit.
CREATE TABLE user_profiles (
  user_id      TEXT PRIMARY KEY NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  display_name TEXT,
  locale       TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);

-- An opaque server session.
--
-- Only the SHA-256 of the token is stored, so a database disclosure does not
-- hand out usable sessions. The plaintext exists once, in the response that
-- created it, and lives in the iOS Keychain from then on.
--
-- Absolute 60-day expiry with no sliding extension; the client rotates by
-- creating a new session when the remaining life falls below half.
CREATE TABLE sessions (
  id           TEXT PRIMARY KEY NOT NULL,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Lowercase hex SHA-256 of the opaque token.
  token_sha256 TEXT NOT NULL UNIQUE,
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  -- Set on logout, unlink, or account deletion. Revocation must be
  -- immediate and server-side, which is why sessions are stored at all
  -- rather than being self-contained tokens.
  revoked_at   INTEGER,
  -- Free-text device label for a future "signed-in devices" screen.
  device_name  TEXT
);

CREATE INDEX idx_sessions_user ON sessions (user_id);
-- Expiry sweeps.
CREATE INDEX idx_sessions_expires ON sessions (expires_at);

-- The pull cursor for sync, one row per user.
--
-- A per-user monotonic counter rather than a timestamp: clocks skew, and two
-- writes inside the same second must still be ordered. Every future syncable
-- row carries the `change_seq` it was written at, and a client pulls
-- everything greater than the sequence it last saw.
CREATE TABLE user_change_seq (
  user_id TEXT PRIMARY KEY NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  seq     INTEGER NOT NULL DEFAULT 0
);
