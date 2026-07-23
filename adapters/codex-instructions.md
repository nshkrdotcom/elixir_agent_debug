## Elixir/OTP debugging

For Elixir or Erlang debugging, use `$elixir-debug`. Explore plausible causes
broadly when the failure is ambiguous — escalating to a wide ranked hypothesis
sweep when it resists localization — batch only independent low-perturbation
observations, and keep speculative mutations attributable and reversible.
Prefer the cheapest evidence appropriate to the symptom. Before adding
temporary inline instrumentation, run `beam-debug begin`; mark every
diagnostic line with its token in the language's comment syntax
(`# BEAMDBG:<token>` in Elixir, `% BEAMDBG:<token>` in Erlang) and finish with
`beam-debug end`, which verifies your own markers are gone — even if
committed. Never remove BEAMDBG markers that are not your session's; the
whole-worktree `beam-debug scan`/`assert-clean` audit is for explicit user
requests only.
