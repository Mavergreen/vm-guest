# 0001 — GPU passthrough is out of scope

Date: 2026-09-17
Status: accepted

## Context

The performance brief's Phase 5 planned GPU passthrough as the only route to
real graphics acceleration, since without a GPU that 10.9 has drivers for
there is no Quartz Extreme or Core Image and the CPU draws everything. It
called for surveying free PCIe slots, power supply, IOMMU groups, and
candidate cards — likely NVIDIA Kepler or AMD Radeon HD 7000-class — then
writing a `PASSTHROUGH-PLAN.md`.

## Decision

Cut the phase. Record the finding instead.

## Reasoning

The host is a `Macmini8,1`. It has **no PCIe slots** and exactly one display
device, the CoffeeLake-H UHD 630 iGPU at `00:02.0`. There is no card to pass
through and nowhere to install one. IOMMU is enabled with 14 groups, but that
is moot.

Passing through the iGPU itself is not viable: it is the host's only display
output, and Intel GVT-g does not cover Coffee Lake in a way 10.9 could use
even if it did.

A Thunderbolt eGPU is the only physical possibility. It would require
acquiring hardware, and eGPU passthrough on a T2 Mac running a T2-patched
Linux kernel is an unproven combination stacked on an already-unproven one.
Not a foundation to plan a phase on.

## Consequences

- The effort is reinvested in P5's display-transport comparison — GTK versus
  SDL versus QEMU's VNC server versus 10.9's own Screen Sharing — which on
  this host is where the interactive wins most plausibly are.
- No `PASSTHROUGH-PLAN.md` is written.
- The guest will not have 3D acceleration. This is a known, accepted
  limitation, and it should be stated in the final report rather than
  discovered by the user.
- If the primary host ever changes to a machine with slots, revisit this. The
  brief's research plan is preserved in git history at commit `a4ba4ce`.
