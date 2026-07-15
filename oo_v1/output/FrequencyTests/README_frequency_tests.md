# Frequency tests — reader's guide

A plain-English guide to what is in `output/FrequencyTests/`, how the runs were set up, and how to
read each plot in the A4 comparison PDFs. Full technical write-up:
`docs/geo_uplink_frequency_analysis.md`.

---

## 1. What this study is

The simulation is a **reverse GNSS**: the ground towers transmit and the GEO spacecraft receives and
navigates itself — the **Earth-to-space (uplink)** direction. The GPS L1/L2 carriers the code
normally uses (1.575 / 1.228 GHz) are **downlink** (space-to-Earth) allocations, so they are *not*
generally licensable for a ground station to transmit up to a satellite. This study sweeps
physically-motivated **uplink** carrier pairs to see how the choice of band changes the solution.

## 2. What was varied — 3 grades × 5 carrier pairs × 2 topologies = 30 runs

**Carrier pairs** (labelled `L1#L2` in GHz; L1 = higher/primary):

| tag | band | why |
|---|---|---|
| `1.58#1.23` | L-band (GPS ref) | anchor / not uplink-legal |
| `2.11#2.02` | S-band uplink | realistic narrow TT&C-style uplink |
| `6.42#5.92` | C-band uplink | realistic wide FSS/RNSS uplink |
| `5.00#2.10` | C/S split | RNSS-5 GHz + S tone; best-conditioned dual-frequency |
| `8.40#7.90` | X-band uplink | very low ionosphere, government band |

**Grades** (how "honest" the simulation is — these differ ONLY as noted):

- **idealised** — realistic atmosphere, but an optimistic (quiet) clock and tight error budget.
- **realism** — realistic atmosphere **plus** honest clock, looser ground-clock product, hardware
  delays, biases, force-model gaps, etc. This is the *physically representative* case.
- **matchedatmo** — same as idealised **but with the atmosphere turned off** (zero ionospheric
  error). Comparing idealised vs matchedatmo isolates exactly what the ionosphere costs.

**Topologies** (Towers = 5, one-way):

- **G5S1R4** — ground-only (one spacecraft, 5 towers).
- **G5S6R4** — the spacecraft is aided by a co-observed **swarm** of 5 secondaries (inter-satellite
  links). This is what makes the radial direction observable.

## 3. Folder layout

```
output/FrequencyTests/
  G5S1R4/                         ground-only
    Battery_idealised_<L1>#<L2>/  ┐ per run: clockExact PDF + figures + .mat
    Battery_realism_<L1>#<L2>/    ├ (5 pairs × 3 grades = 15 runs)
    Battery_matchedatmo_<L1>#<L2>/┘
    analysis/                     comparison of the 15 G5S1R4 runs
  G5S6R4/                         swarm-aided (same structure, 15 runs)
    analysis/
  analysis_all/                   comparison of ALL 30 runs
```

Each `analysis/` (and `analysis_all/`) contains:
- **`comparison_A4.pdf`** — the readable deliverable: **one big plot per A4-landscape page** (12 pages),
  x-axis ordered by ascending primary frequency. The 3 convergence time-series are each split into a
  separate **idealised** and **realism** page (6 pages) so the lines stay readable; on those pages
  **colour = carrier band** and **line style = topology (S1 solid, S6 dashed)**.
- `comparison_report.md` / `.pdf` — the numbers (ranked tables + auto-interpretation).
- `comparison_metrics.csv` — one row per run, every metric.
- `comparison_overview.png`, `radial_clock_timeseries.png` — the same plots as a dense single image.

**Scope of the comparison plots:** the `comparison_*` deliverables compare **idealised + realism
only** (labels like `ideal 6.42/5.92`, `real 6.42/5.92`). The **matchedatmo** runs are still on disk
in every `Battery_matchedatmo_<L1>#<L2>/` folder (with their own per-run PDFs) for the ionosphere-
isolation argument in §5, but are left out of the comparison plots to keep them uncluttered.

## 4. How to read the 9 plots in `comparison_A4.pdf`

Each page has a title and a one-line "how to read" subtitle. In short:

1. **Radial & clock error** — the two error components that collapse into one weakly-observable mode on
   a one-way GEO link. Log axis, metres. If they track each other, the geometry is degenerate.
2. **Horizontal / 3D position & velocity** — along/cross/3D position (bars, left) and velocity (line,
   right). Horizontal is usually well-observed; 3D is dominated by the radial.
3. **Clock bias & rate** — receiver clock error in ns and its drift in mm/s.
4. **NEES per DOF** — a *consistency* check: each channel should sit on the dashed **y = 1** line.
   Bars **far above 1 mean the filter is over-confident** (it believes it is more accurate than it is).
5. **Covariance realism** — filter σ ÷ actual RMS. **< 1 = optimistic/over-confident**, > 1 =
   conservative. The [0.5, 2] band is acceptable.
6. **Geometry / degeneracy** — DOP values (bars) and **corr(radial, clock)** (line). corr near **−1**
   is the signature of the radial↔clock degeneracy.
7–8. **Position error convergence** — 3D error vs time (log axis), on **two pages: idealised then
   realism**. On each, **colour = carrier band**, **solid = S1 (ground-only)**, **dashed = S6 (swarm)**.
   The dashed S6 lines sitting well below the solid S1 lines is the swarm unlocking the radial.
9–10. **Clock error convergence** — |clock error| vs time (idealised, then realism), same encoding.
11–12. **Position consistency (NEES vs time)** — should settle toward the dashed y = 1 (idealised,
   then realism), same encoding.

Bars (plots 1–6) are coloured by series; time-series lines (plots 7–12) are coloured by band and
styled by topology, so a given band keeps the same colour across every page.

## 5. Headline results (see `docs/geo_uplink_frequency_analysis.md §7` for the tables)

1. **The limiting factor is observability, not frequency.** On the ground-only link the radial is
   trapped in the radial↔clock degeneracy (corr = −1 for all 30 runs) and swings wildly (0.8–24.7 m)
   regardless of band — frequency cannot fix it.
2. **The swarm (G5S6R4) unlocks the radial** → idealised/matchedatmo reach **millimetre–centimetre**
   position (best: matched-atmo C-band, 3D ≈ 29 mm, clock ≈ 25 ps). *Then* frequency matters.
3. **matchedatmo isolates the ionosphere cleanly**: with the ionosphere off, position is flat across
   bands, and the `idealised − matchedatmo` gap = the ionosphere cost, which shrinks with band
   (≈ 290 mm at L → ≈ 90 mm at C, i.e. ∝ 1/f²). C-band is the sweet spot.
4. **The narrow S-band pair is the worst realistic uplink** (ionosphere present, no separation to
   remove it).
5. **Honesty caveat:** at G5S6R4 the mm–cm numbers are an *idealised-error* artefact. The
   physically-representative **realism** grade is metre-level there and its covariance is badly
   over-confident (NEES 200–400, radial 3σ coverage 0%). A real swarm design must budget for the
   secondary-product accuracy, not just add links. On plot 4 (NEES) and 5 (covariance realism) the
   `realism` bars are the ones towering above the line — that is this caveat, made visible.
6. **Attitude is L-band-tuned**: L/S-band ≈ 0.12° but C/X ≈ 2–3° — the differential-carrier ambiguity
   resolution needs re-tuning for the shorter wavelengths, not a physics limit.

**Design takeaway:** a credible reverse-GNSS GEO uplink pairs an RNSS/FSS **C-band (~5–6 GHz)**
primary with a widely-separated **S-band (~2 GHz)** tone, **and** uses a co-observed swarm to break
the radial↔clock wall — then budgets honestly for the swarm covariance and re-tunes the attitude
solver to the chosen band.
