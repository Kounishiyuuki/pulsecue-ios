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
