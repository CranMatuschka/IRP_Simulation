# Thesis figures

Every result figure in the thesis is generated here and written as a PDF into the
thesis tree. LaTeX only ever sees the finished PDF.

```
IRP/Codes/IRP_Simulation/thesis_figures/   generators (this folder)
IRP/Test/figures/generated/                the PDFs they write
IRP/Test/figures/data/                     the .dat extracts they read
```

## Regenerate

```bash
cd IRP/Codes/IRP_Simulation/thesis_figures
python3 make_all.py            # every figure
python3 make_all.py ch08       # only generators whose name contains ch08
cd ../../../Test && latexmk -pdf main
```

Requires `numpy`, `matplotlib` and `h5py`. Nothing else, and no MATLAB.

## Files

| File | Purpose |
|---|---|
| `thesisviz.py` | style, palette, figure sizing, `read_dat`, `save`. Import as `tv`. |
| `runs.py` | reads the `.mat` runs: `load_state`, `load_relerror`, `summary`. |
| `make_all.py` | runs every `fig_*.py`. |
| `fig_*.py` | one generator per figure, one PDF each. |

## Rules that keep the figures honest

1. **The `.dat` files are the sanctioned extracts.** They were checked against the
   runs and against the prose, so prefer them. Reach into a `.mat` through
   `runs.py` only for a series no `.dat` carries.
2. **Only 3600 s runs.** `runs.py` raises on anything else, so a smoke fixture
   cannot reach a figure. Rungs resolve from the frozen sweep first
   (`oo_v1/IRP Ladder Results Final`), then the latest report folders, which is
   the rule the thesis text follows.
3. **Never compute a clock error as state minus stored truth.** The stored truth
   clock carries the relativistic rate offset, so the difference is a ramp of
   hundreds of nanoseconds and is not the estimation error. `runs.load_state`
   deliberately does not return a clock series. Take it from the `.dat`.
4. **Position error over time is always resolved into components**, never a single
   norm, one panel per axis on a shared scale. The filter state is Earth-fixed,
   so the components are Earth-fixed x, y and z and the stored covariance diagonal
   belongs to that same frame. `load_state` checks that the components reproduce
   the run's own stored norm and raises if they do not.
5. **No number is invented.** Everything a figure shows is in a `.dat`, in a run,
   or is exact arithmetic on them.

## Style

Figures are built at their final printed size (text width is 426.79 pt, so
5.906 in) and included at `width=\textwidth`, which prints them 1:1 and keeps the
label sizes set in `thesisviz`. Never save with `bbox_inches="tight"`, it changes
the size and breaks that.

The palette is a validated eight-slot categorical set assigned in fixed order and
never cycled, plus a blue sequential ramp and a reserved status set. Three slots
sit below 3:1 contrast on white, so every series carries a legend entry or a
direct label and hue never carries meaning alone. Scatter plots, where every pair
of series is compared at once, use at most three slots. There is never a second
y axis: two measures of different scale become two panels.

## Adding a figure

Copy the shortest existing generator, keep the `main()` entry point so
`make_all.py` finds it, call `tv.save(fig, "name")`, and include it in LaTeX as
`\includegraphics[width=\textwidth]{generated/name.pdf}`. Then render the PDF to
PNG and look at it before committing: the palette is validated by script, the
layout is not.
