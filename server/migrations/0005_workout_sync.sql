-- 0005_workout_sync
--
-- The first slice of synced data: workout sessions and their step results.
--
-- Scope is deliberately two tables. Routines, gyms, day logs and meals are
-- not here — a sync design is easier to get right on the smallest thing that
-- is genuinely useful, and everything after this hangs off the same
-- `user_id` + `change_seq` shape.
--
-- **Ids come from the client.** The app already generates UUIDs for these
-- records offline, and rewriting them on upload would mean the device and the
-- server disagree about what a record is called — which makes a retry
-- indistinguishable from a new record. So the client's id is the id.
--
-- That makes ownership the thing to be careful about, and it is why the
-- primary key is `(user_id, id)` rather than `id`:
--
--   * Two users can hold the same UUID without either one silently
--     overwriting the other. With a bare `id` primary key, a client that
--     guessed or replayed someone else's UUID would land on their row.
--   * Every lookup is forced to carry a user. There is no way to write a
--     query against these tables that "forgets" whose data it is reading,
--     because the key does not permit it.
--
-- `step_results` points at its session through `(user_id, session_id)`, so a
-- step result cannot reference a session belonging to somebody else — the
-- foreign key makes that unrepresentable rather than merely discouraged.
--
-- `change_seq` on every row is the pull cursor: a client asks for everything
-- greater than the sequence it last saw. One sequence value per upload batch,
-- taken inside the same transaction that writes the rows, so a reader can
-- never see a row whose sequence has not been published — or a published
-- sequence with no rows behind it.

PRAGMA foreign_keys = ON;

CREATE TABLE workout_sessions (
  -- Client-generated UUID. Unique per user, not globally.
  id          TEXT NOT NULL,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  started_at  INTEGER NOT NULL,
  ended_at    INTEGER,
  title       TEXT,
  -- The sequence this row was last written at. Pull cursor.
  change_seq  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  -- Tombstone. A delete has to be *visible* to other devices, so the row is
  -- marked rather than removed; a client pulling past this sequence learns
  -- the record is gone. Hard deletion happens with the account.
  deleted_at  INTEGER,
  PRIMARY KEY (user_id, id)
);

-- The pull query: "everything of mine newer than X", in order.
CREATE INDEX idx_workout_sessions_pull
  ON workout_sessions (user_id, change_seq);

CREATE TABLE step_results (
  id               TEXT NOT NULL,
  user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id       TEXT NOT NULL,
  exercise_name    TEXT NOT NULL,
  -- Position within the session. The client's order, preserved.
  order_index      INTEGER NOT NULL,
  reps             INTEGER,
  weight_kg        REAL,
  duration_seconds INTEGER,
  completed_at     INTEGER,
  change_seq       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  deleted_at       INTEGER,
  PRIMARY KEY (user_id, id),
  -- Carries `user_id` into the reference on purpose: a step result cannot
  -- point at another user's session, because there is no such key to point at.
  FOREIGN KEY (user_id, session_id)
    REFERENCES workout_sessions (user_id, id) ON DELETE CASCADE
);

CREATE INDEX idx_step_results_pull
  ON step_results (user_id, change_seq);

CREATE INDEX idx_step_results_session
  ON step_results (user_id, session_id);

-- ---------------------------------------------------------------------------
-- Write-time invariants, enforced by the database rather than by the caller.
--
-- Both of the rules below were previously checked only in application code,
-- and both had the same shape of hole: the check ran, the code awaited
-- something, and by the time the write landed the answer had changed. A
-- request that passed the session middleware while the account was active
-- could commit rows after another request moved that account to 'deleting';
-- a stale upload could clear a tombstone written after it was composed.
--
-- Triggers close those windows because they run *inside the same transaction
-- as the write*. There is no gap to lose a race in, and no internal caller —
-- present or future, route or script — that can route around them.
--
-- `RAISE(ABORT, ...)` rolls the whole batch back, so an upload never lands
-- half of its rows.

-- 1. Only an active account may have sync rows written for it.
--
-- Deleting an account is the destructive, irreversible action in this system;
-- accepting new data for one that is on its way out means writing rows the
-- deletion has already walked past.

CREATE TRIGGER trg_workout_sessions_require_active_user_insert
BEFORE INSERT ON workout_sessions
FOR EACH ROW
WHEN (SELECT state FROM users WHERE id = NEW.user_id) <> 'active'
BEGIN
  SELECT RAISE(ABORT, 'sync_user_not_active');
END;

CREATE TRIGGER trg_workout_sessions_require_active_user_update
BEFORE UPDATE ON workout_sessions
FOR EACH ROW
WHEN (SELECT state FROM users WHERE id = NEW.user_id) <> 'active'
BEGIN
  SELECT RAISE(ABORT, 'sync_user_not_active');
END;

CREATE TRIGGER trg_step_results_require_active_user_insert
BEFORE INSERT ON step_results
FOR EACH ROW
WHEN (SELECT state FROM users WHERE id = NEW.user_id) <> 'active'
BEGIN
  SELECT RAISE(ABORT, 'sync_user_not_active');
END;

CREATE TRIGGER trg_step_results_require_active_user_update
BEFORE UPDATE ON step_results
FOR EACH ROW
WHEN (SELECT state FROM users WHERE id = NEW.user_id) <> 'active'
BEGIN
  SELECT RAISE(ABORT, 'sync_user_not_active');
END;

-- 2. A tombstone is terminal.
--
-- v1 conflict policy: once a record is deleted on the server, that id is
-- finished. An upload composed before the delete still carries the record as
-- live, and a plain upsert would clear `deleted_at` and bring it back — on
-- every other device too, since the resurrection gets its own change_seq.
--
-- Re-sending the same delete is fine (deleted_at stays set); only clearing it
-- is refused. A record that genuinely needs to come back gets a new id, which
-- is unambiguous in a way that reviving an id never is.

CREATE TRIGGER trg_workout_sessions_tombstone_is_terminal
BEFORE UPDATE ON workout_sessions
FOR EACH ROW
WHEN OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
BEGIN
  SELECT RAISE(ABORT, 'sync_tombstone_is_terminal');
END;

CREATE TRIGGER trg_step_results_tombstone_is_terminal
BEFORE UPDATE ON step_results
FOR EACH ROW
WHEN OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
BEGIN
  SELECT RAISE(ABORT, 'sync_tombstone_is_terminal');
END;
