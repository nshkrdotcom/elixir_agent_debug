## Elixir/OTP debugging

For Elixir or Erlang debugging, use the `elixir-debug` skill. Explore plausible
causes broadly when the failure is ambiguous — escalating to a wide ranked
hypothesis sweep when it resists localization — batch only independent
low-perturbation observations, and keep speculative mutations attributable and
reversible. Prefer the cheapest evidence appropriate to the symptom. Mark every
temporary diagnostic line with the literal `BEAMDBG` marker in the language's
comment syntax — `# BEAMDBG` in Elixir, `% BEAMDBG` in Erlang — and remove it
before finishing (`beam-debug assert-clean` verifies). If you ran
`beam-debug begin`, use its tokened form (`# BEAMDBG:<token>`) and finish with
`beam-debug end`; never remove markers you did not add this session.
