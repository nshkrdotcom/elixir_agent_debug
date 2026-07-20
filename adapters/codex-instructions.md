## Elixir/OTP debugging

For Elixir or Erlang debugging, use `$elixir-debug`. Prefer a tight one-theory
-> one empirical check -> observe -> revise loop. Temporary inline `dbg`,
`IO.inspect`, or `Logger.debug` is the default quick check when it puts the
evidence directly in the current test output; mark every temporary source line
with `# BEAMDBG` and remove it in the same turn. Make no more than one
speculative code change between checks. Before finishing, run
`beam-debug assert-clean` and the narrowest relevant regression test.
