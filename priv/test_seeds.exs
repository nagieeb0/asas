# Seed script for Asas.ReleaseTest. Deliberately NOT idempotent: it appends a row
# every time it runs, so a second execution is visible rather than invisible.
Ecto.Adapters.SQL.query!(
  Asas.TestRepo,
  "INSERT INTO asas_seed_marker (note) VALUES ($1)",
  ["seeded"]
)
