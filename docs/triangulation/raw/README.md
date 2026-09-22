# Raw host diagnostics

Command output pasted from a triangulation host, kept because a summary
is not the evidence.

- `macpro-lscpu.txt`, `macpro-dmesg-cpu.txt` — `ap-juicer` (Mac Pro 1,1),
  2026-09-21. These settled what looked like a parsing bug in
  `bin/triangulate.sh` and was not one: `cpu_cores 4, cpu_logical 3`,
  because **`CPU3 failed to report alive state`** — a core that did not
  come up during SMP boot. Hardware on a nineteen-year-old machine, not
  configuration, and a fact that changes every timing recorded there.
  See `../2026-09-21-ap-juicer-probe.md`.

Everything else a triangulation run produces now lands in
`triangulate-logs-<host>-<stamp>/` next to the repo — gitignored, because
`pipeline.log` and the firmware build logs are megabytes. Those are
transient; what matters from them gets written up in `docs/triangulation/`
and into the ledger in `docs/host-profile.md`.
