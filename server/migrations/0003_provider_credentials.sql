-- 0003_provider_credentials
--
-- Encrypted storage for provider refresh tokens.
--
-- Only one thing needs this: Apple requires an app offering Sign in with
-- Apple to revoke the token when the user deletes their account, and the
-- revoke call needs a refresh token. The token is obtained by exchanging the
-- single-use `authorizationCode` during sign-in — it cannot be fetched later,
-- which is why it is stored at all rather than acquired at deletion time.
--
-- What is NOT stored: access tokens (never used), id tokens (verified and
-- discarded), and authorization codes (single-use, spent immediately). The
-- schema test asserts those column names do not appear.
--
-- The refresh token is never written in plaintext. `encrypted_refresh_token`
-- is AES-256-GCM ciphertext, `encryption_iv` the per-write random 96-bit IV,
-- and `encryption_key_version` names the key so a rotation does not orphan
-- rows. The GCM additional data binds the ciphertext to this row's
-- `auth_identity_id` and provider, so a ciphertext copied onto a different
-- identity fails to decrypt rather than revoking the wrong person's account.

PRAGMA foreign_keys = ON;

CREATE TABLE provider_credentials (
  id                      TEXT PRIMARY KEY NOT NULL,
  -- Deleting the identity (or the user above it) destroys the credential.
  -- Account deletion must not be able to leave one behind.
  auth_identity_id        TEXT NOT NULL REFERENCES auth_identities(id) ON DELETE CASCADE,
  provider                TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  -- Base64 AES-256-GCM ciphertext, tag included. Never plaintext.
  encrypted_refresh_token TEXT NOT NULL,
  -- Base64 96-bit IV, freshly generated on every write. Reuse under one key
  -- is how GCM fails catastrophically, so it is stored per row and never
  -- derived or defaulted.
  encryption_iv           TEXT NOT NULL,
  encryption_key_version  INTEGER NOT NULL,
  created_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL,
  -- Set when the token has been revoked at the provider. The row is kept
  -- briefly so a deletion retry does not try to revoke it twice; the
  -- material itself is blanked at the same time.
  revoked_at              INTEGER,
  -- One credential per identity. A repeat sign-in replaces it rather than
  -- accumulating rows nobody can tell apart.
  UNIQUE (auth_identity_id)
);

CREATE INDEX idx_provider_credentials_identity
  ON provider_credentials (auth_identity_id);
