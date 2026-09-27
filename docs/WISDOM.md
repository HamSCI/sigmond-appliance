# FFTW wisdom: where it comes from, and what it is optimised for

`wisdomf-ryzen5825u` and `wisdom-radiod-plans-ryzen5825u` are **the same
file**. Two copies exist because two different loaders go looking:
`fftwf_import_system_wisdom()` reads `/etc/fftw/wisdomf`, and ka9q-radio
additionally reads `/var/lib/ka9q-radio/wisdom-fftw-<version>-threaded`.
Same format, same contents — verified on W3USR-06 2026-09-27, both loaders
reporting `succeeded` against one identical 347-plan file.

## Provenance — the thing the previous files did not have

    generated   2026-09-27
    host        W3USR-06 decoder VM (DASI-006, Scranton penthouse)
    CPU         AMD Ryzen 7 5825U, 14 vCPU, L3 16 MiB (1 instance, unpartitioned)
    RAM         9 GB   — production decoder-VM geometry, matching AC0G-B4
    FFTW        3.3.10-sse2-avx
    rigor       FFTW_PATIENT
    threads     internal-threads 1, matching radiod's `fft-threads = 1`
    pinned      CPUs 12,13 — the hyperthread sibling pair radiod runs on
    load        idle; the full station stack stopped, load < 0.4
    plans       347, covering 51 transforms

The files this replaces (157 and 193 plans) had no recorded origin at all.
A third file of 1009 plans was found on the build rig with no date, no host
and no rigor — and it was NOT a superset: 57 plans existed only in the
157-plan file. That is the state this document exists to prevent.

## ⚠ What it is optimised FOR

Planned on an **idle** machine, so the plans assume near-exclusive use of
the 16 MiB L3. In production radiod shares that cache with the decoders, and
the best plan under contention may not be the best plan on a quiet box. This
was a deliberate choice (rob, 2026-09-27) — production *geometry*, idle
*machine* — not an oversight. Re-planning under representative load is a
legitimate future experiment.

On a CPU with a different cache size FFTW ignores non-matching wisdom and
falls back to runtime planning, so a wrong-silicon file costs nothing but
the space.

## How the transform list was built — and why a sweep is required

radiod NEVER plans well at runtime. `filter.c` asks for
`FFTW_WISDOM_ONLY|<rigor>` and, on a miss, falls silently to
`FFTW_ESTIMATE` — suboptimal forever, invisible in startup time. It records
each miss in `/var/lib/ka9q-radio/fft.log`, in `fft-gen`'s own problem
syntax. **That log is the only honest inventory of what a station needs.**

It took four rounds, because each pass can only surface what is actually
being exercised:

    round 1   41  rob's ka9q-web zoom-level walk + radiod's rof3240000
    round 2    6  decoder channel filters — appear only when psk/wspr/meteor
                  request channels
    round 3    4  spectrum sizes a SECOND zoom walk surfaced that the first
                  missed
    round 4    2  cob1200/cif1200 (48 kHz IQ) — added deliberately; no
                  channel on the box uses 48 kHz, so no sweep would ever
                  have found it

Verification is `wc -l /var/lib/ka9q-radio/fft.log` on a running station
with every service up and the zoom levels walked. **0 == fully planned.**

## EXHAUSTIVE was tried, measured, and REJECTED

A 10-hour `--exhaustive --force` re-plan of `rof3240000` produced a
*different* plan (360 plans vs 347) that benchmarked **6-8% SLOWER**,
reproducibly, interleaved A/B/B/A at 40 iterations on an idle box:

    PATIENT      7.667 / 7.593 ms best
    EXHAUSTIVE   8.146 / 8.191 ms best

EXHAUSTIVE searches wider and keeps whatever timed fastest *during
planning*; over a long unattended run a single lucky measurement on a
marginal variant wins, and it overfits the noise. The rejected file is kept
on W3USR-06 as `wisdom.EXHAUSTIVE-360-REJECTED-20260927`.

⛔ Do not "upgrade" this to EXHAUSTIVE on the assumption that more rigor is
better. It was tried on real hardware and it is worse.
