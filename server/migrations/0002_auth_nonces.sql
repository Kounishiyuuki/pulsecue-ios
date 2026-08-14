-- 0002_auth_nonces
--
-- Single-use nonces for provider sign-in.
--
-- Verifying the identity token proves Apple signed it and that it is bound
-- to a nonce, but not that the request is fresh: replaying the exact same
-- body would pass every signature and claim check until the token expires.
-- Recording the nonce the first time it is accepted turns that window from
-- "several minutes" into "once".
--
-- Only the SHA-256 of the nonce is stored. It is not a credential, but it
-- is per-sign-in user-linkable material and there is no reason to keep the
-- original.
CREATE TABLE auth_nonces (
  nonce_sha256 TEXT PRIMARY KEY NOT NULL,
  provider     TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  used_at      INTEGER NOT NULL,
  -- The identity token's own expiry. After this instant a replay would be
  -- rejected for being expired anyway, so the row can be swept.
  expires_at   INTEGER NOT NULL
);

CREATE INDEX idx_auth_nonces_expires ON auth_nonces (expires_at);
