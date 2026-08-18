-- 0004_account_deletions
--
-- Retry state for an account deletion that is under way.
--
-- Deletion is not a single atomic act. Marking the account and revoking its
-- sessions are local and immediate, but revoking the Apple refresh token is a
-- call to someone else's service that can simply be down. That leaves a gap,
-- and the gap needs somewhere to live.
--
-- The rule this table exists to keep: **a failed provider revocation never
-- puts the account back.** `users.state` stays 'deleting', every session
-- stays revoked, and the request is retried later. Rolling back to 'active'
-- because Apple had a bad minute would resurrect an account the user asked to
-- destroy — and would do it silently.
--
-- The row is deliberately small and boring. `last_error_code` holds a value
-- from a closed set defined in code, never a provider message and never
-- anything derived from user data: this table describes a *job*, not a person.
--
-- It carries no completion state. A finished deletion removes the user, and
-- the cascade removes this row with it — so "still here" means "still owed",
-- and there is no way for the two to disagree.

PRAGMA foreign_keys = ON;

CREATE TABLE account_deletions (
  -- One in-flight deletion per user, enforced by the key rather than by a
  -- check somewhere in the code.
  user_id         TEXT PRIMARY KEY NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  requested_at    INTEGER NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_attempt_at INTEGER,
  -- A fixed code from a closed set. Never a provider error body, never PII.
  last_error_code TEXT,
  -- When a processor may try again. Backoff lives here rather than in a
  -- scheduler so the retry policy survives whatever invokes it.
  next_attempt_at INTEGER NOT NULL
);

-- The pending-work query: "what is due now".
CREATE INDEX idx_account_deletions_next_attempt
  ON account_deletions (next_attempt_at);
