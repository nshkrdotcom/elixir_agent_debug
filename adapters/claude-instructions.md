## Elixir/OTP debugging

For Elixir or Erlang debugging, use the `elixir-debug` skill. Explore plausible
causes broadly when the failure is ambiguous, batch only independent
low-perturbation observations, and keep speculative mutations attributable and
reversible. Prefer the cheapest evidence appropriate to the symptom. Mark every
temporary diagnostic line with `# BEAMDBG` and remove it before finishing
(`beam-debug assert-clean` verifies).
