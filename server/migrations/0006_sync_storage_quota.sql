-- 0006_sync_storage_quota
--
-- A per-user ceiling on how many sync rows the server will store.
--
-- The rate limiter bounds how *fast* a user can write; nothing bounded how
-- *much*. A client looping over fresh UUIDs could grow D1 without limit at a
-- perfectly polite request rate. This is the persistent half of that defence.
--
-- **What counts is physical rows.** A tombstone is a row: it occupies storage
-- and it is never purged in v1. Excluding tombstones would let create→delete
-- cycles grow the database forever while the quota reported room to spare.
-- Freeing quota belongs with a tombstone purge, not before it.
--
-- **Why a counter, maintained by triggers, guarded by CHECK.** The obvious
-- version — count, compare, then write — has a gap between the count and the
-- write that two concurrent uploads can both pass through. Here the counter
-- moves inside the same transaction as the row, and the CHECK is evaluated on
-- that same write. There is no read-then-decide step to lose a race in, and
-- no caller (route, script, future endpoint) that can write a row without
-- moving the counter.
--
-- Only a genuine insert counts. An upsert that resolves to UPDATE fires the
-- UPDATE triggers, not AFTER INSERT, so editing a record or retrying the same
-- upload costs nothing. (BEFORE INSERT would be wrong here: it fires before
-- conflict resolution, i.e. on updates too.)
--
-- A violated CHECK aborts the statement, and the upload is one `db.batch()`,
-- so the whole request rolls back: no sequence bump, no partial rows, no
-- counter drift.
--
-- The constraint names are matched by the repository to produce
-- `storage_quota_exceeded`. Renaming one is an API change.

PRAGMA foreign_keys = ON;

CREATE TABLE user_storage_usage (
  user_id           TEXT PRIMARY KEY NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_count     INTEGER NOT NULL DEFAULT 0,
  step_result_count INTEGER NOT NULL DEFAULT 0,
  -- The quotas.
  CONSTRAINT storage_quota_sessions     CHECK (session_count <= 10000),
  CONSTRAINT storage_quota_step_results CHECK (step_result_count <= 100000),
  -- A negative count means the counter and the rows disagree. Named apart
  -- from the quotas so drift is never reported to a client as "full".
  CONSTRAINT storage_usage_sessions_nonnegative     CHECK (session_count >= 0),
  CONSTRAINT storage_usage_step_results_nonnegative CHECK (step_result_count >= 0)
);

-- Every user gets a usage row the moment they exist, inside the account
-- creation batch. A trigger rather than a statement in that batch: it also
-- covers accounts created between this migration and the code that knows
-- about the table, which would otherwise be locked out of sync for good.
CREATE TRIGGER trg_users_create_storage_usage
AFTER INSERT ON users
FOR EACH ROW
BEGIN
  INSERT INTO user_storage_usage (user_id) VALUES (NEW.id);
END;

-- The UPDATE matching nothing would silently skip the quota, so a missing
-- usage row fails the write instead.
CREATE TRIGGER trg_workout_sessions_count_insert
AFTER INSERT ON workout_sessions
FOR EACH ROW
BEGIN
  UPDATE user_storage_usage SET session_count = session_count + 1
   WHERE user_id = NEW.user_id;
  SELECT RAISE(ABORT, 'storage_usage_missing')
   WHERE NOT EXISTS (SELECT 1 FROM user_storage_usage WHERE user_id = NEW.user_id);
END;

-- Only reached through the account-deletion cascade today. If the usage row
-- has already cascaded away the UPDATE matches nothing, which is correct.
CREATE TRIGGER trg_workout_sessions_count_delete
AFTER DELETE ON workout_sessions
FOR EACH ROW
BEGIN
  UPDATE user_storage_usage SET session_count = session_count - 1
   WHERE user_id = OLD.user_id;
END;

CREATE TRIGGER trg_step_results_count_insert
AFTER INSERT ON step_results
FOR EACH ROW
BEGIN
  UPDATE user_storage_usage SET step_result_count = step_result_count + 1
   WHERE user_id = NEW.user_id;
  SELECT RAISE(ABORT, 'storage_usage_missing')
   WHERE NOT EXISTS (SELECT 1 FROM user_storage_usage WHERE user_id = NEW.user_id);
END;

CREATE TRIGGER trg_step_results_count_delete
AFTER DELETE ON step_results
FOR EACH ROW
BEGIN
  UPDATE user_storage_usage SET step_result_count = step_result_count - 1
   WHERE user_id = OLD.user_id;
END;

-- A sync row's owner never changes.
--
-- The counters above move on INSERT and DELETE only. An UPDATE that moved a
-- row from one user to another would leave both counters wrong, silently.
-- Rather than teach the counters about transfers, a transfer is refused: no
-- feature needs one, and the upserts never set `user_id`, so ordinary updates
-- and retries never reach these triggers' condition.

CREATE TRIGGER trg_workout_sessions_owner_is_immutable
BEFORE UPDATE OF user_id ON workout_sessions
FOR EACH ROW
WHEN OLD.user_id <> NEW.user_id
BEGIN
  SELECT RAISE(ABORT, 'sync_owner_is_immutable');
END;

CREATE TRIGGER trg_step_results_owner_is_immutable
BEFORE UPDATE OF user_id ON step_results
FOR EACH ROW
WHEN OLD.user_id <> NEW.user_id
BEGIN
  SELECT RAISE(ABORT, 'sync_owner_is_immutable');
END;

-- Backfill every existing user, including those with no sync rows.
--
-- Runs after the triggers exist, so a row written mid-migration either fails
-- (no usage row yet) or is counted here — never neither. A user already over
-- quota fails the CHECK and the migration with it: an over-limit account is
-- for a person to look at, not something to clamp or truncate silently.
--
-- DO NOTHING: an account created after the users trigger above already has a
-- row, and the triggers have kept it exact since. (`WHERE true` is SQLite's
-- required disambiguation for an upsert on INSERT ... SELECT.)
INSERT INTO user_storage_usage (user_id, session_count, step_result_count)
SELECT u.id,
       (SELECT COUNT(*) FROM workout_sessions AS s WHERE s.user_id = u.id),
       (SELECT COUNT(*) FROM step_results     AS r WHERE r.user_id = u.id)
  FROM users AS u
 WHERE true
ON CONFLICT (user_id) DO NOTHING;
