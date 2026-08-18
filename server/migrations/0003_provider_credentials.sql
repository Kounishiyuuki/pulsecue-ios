-- 0003_provider_credentials
--
-- Encrypted storage for provider refresh tokens, plus two invariants the
-- database enforces so no caller has to remember them.
--
-- Only one thing needs credential storage: Apple requires an app offering
-- Sign in with Apple to revoke the token when the user deletes their account,
-- and the revoke call needs a refresh token. The token is obtained by
-- exchanging the single-use `authorizationCode` during sign-in — it cannot be
-- fetched later, which is why it is stored at all rather than acquired at
-- deletion time.
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

-- Lets `provider_credentials` reference (identity, provider) as a pair.
-- `id` alone is already the primary key of `auth_identities`; this index adds
-- nothing to uniqueness and exists purely so the composite foreign key below
-- has a key to point at.
CREATE UNIQUE INDEX idx_auth_identities_id_provider
  ON auth_identities (id, provider);

CREATE TABLE provider_credentials (
  id                      TEXT PRIMARY KEY NOT NULL,
  auth_identity_id        TEXT NOT NULL,
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
  -- Set once the token has been revoked at the provider — which means an
  -- Apple HTTP 2xx and nothing weaker. The row is kept briefly so a deletion
  -- retry can tell "already revoked" from "never had one"; the material
  -- itself is blanked at the same time.
  revoked_at              INTEGER,
  -- One credential per identity. A repeat sign-in replaces it rather than
  -- accumulating rows nobody can tell apart.
  UNIQUE (auth_identity_id),
  -- **Provider consistency, enforced by the database.**
  --
  -- The reference carries `provider` as well as the id, so a credential row
  -- claiming `google` can only attach to an identity that really is `google`.
  -- Storing an Apple refresh token against a Google identity would otherwise
  -- be writable, and it would corrupt two things at once: deletion would try
  -- to revoke the wrong provider, and the ciphertext's AAD — which binds the
  -- provider name — would no longer open. Making the pair unrepresentable is
  -- cheaper than checking it at every call site.
  FOREIGN KEY (auth_identity_id, provider)
    REFERENCES auth_identities (id, provider) ON DELETE CASCADE
);

CREATE INDEX idx_provider_credentials_identity
  ON provider_credentials (auth_identity_id);

-- **A session may only be created for an active user — as a statement
-- failure, not as a silently empty write.**
--
-- The guard used to live in the INSERT itself:
--
--   INSERT INTO sessions … SELECT … WHERE EXISTS (… state = 'active' …)
--
-- which is correct about *what* it writes and dangerously wrong about how it
-- fails. Inserting zero rows is a **successful** statement. D1 only rolls a
-- batch back when a statement errors, so a batch of
-- [credential UPSERT, session INSERT] against a `deleting` user committed the
-- credential and silently issued no session — exactly the half-state the
-- batch existed to prevent, and invisible to any test that only asserted "no
-- session was created".
--
-- A trigger turns that non-event into a real error, so the whole batch rolls
-- back. The session INSERT is now unconditional and this is the only guard.
--
-- Scoped to session creation on purpose. A `deleting` account must still be
-- able to *hold* its encrypted credential, because that is what deletion
-- revokes with — so nothing here constrains `provider_credentials`.
CREATE TRIGGER sessions_require_active_user
BEFORE INSERT ON sessions
FOR EACH ROW
WHEN (SELECT state FROM users WHERE id = NEW.user_id) IS NOT 'active'
BEGIN
  SELECT RAISE(ABORT, 'session requires an active user');
END;
