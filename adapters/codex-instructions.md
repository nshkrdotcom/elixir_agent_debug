## Elixir/OTP debugging

For Elixir or Erlang debugging, use `$elixir-debug`. Generate broadly, test
efficiently, edit cautiously: form a ranked set of hypotheses rather than
committing to the first one, batch independent read-only checks into one run,
and let the observed evidence do the eliminating. Start from the symptom
(deterministic / flaky / hangs / crashes / wrong state / slow / memory /
regression), not from a fixed tool order. Prefer observation that edits nothing
— `beam-debug trace` for an MFA, `beam-debug snapshot` for a hang or live state
— and use temporary inline `dbg`/`IO.inspect` for already-localized data-flow
errors, marking every temporary line with `# BEAMDBG` and removing it in the
same turn. Do not combine unrelated speculative fixes in one patch, and keep
each verification cycle causally interpretable. Before finishing, run
`beam-debug assert-clean` and the narrowest relevant regression test.
