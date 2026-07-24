# pre-PR #132 V3 fixture

`pre_pr132_v3.sqlite` was generated from detached commit
`1974ab87200d4f9e023e57b2815717885b0f6cc7` using that commit's actual
top-level `Step` and `PulseCueSchemaV3`.

The temporary exporter inserted fixed representative `Routine`, two `Step`
rows, `Session`, `StepResult`, `Gym`, `GymMachine`, and `CustomMachine`
records. The exporter was run only in a temporary worktree and was not
committed. `StepExerciseIdMigrationTests` copies this fixture to a unique
temporary directory and opens the copied store with the current
`PulseCueSchemaV4` and `PulseCueMigrationPlan`.

Fixture SHA-256:
`683042138e89e37267b91e6bb0e2bcae687d58d8762ec3c8de4f1d71652a1f01`.

This fixture proves an actual pre-PR #132 source-generated V3 store can
migrate. The separate synthetic V3 fixture remains in place to exercise
current historical-schema construction directly.
