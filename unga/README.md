# unga

Topics in UN General Assembly speeches, how they change over time, and stance toward a claim within one topic. Adapted from hot_topic: the paragraphs are already clean units, so there is no embedding or merging step.

```
input/unga.parquet    id, para_id, year, country, raw_text (one row per paragraph)
code/topics.qmd       step 1: STM topics, codebook, prevalence trends
code/stance.R         step 2: stance on one claim within one topic
code/unga_source.R    shared functions
code/unga_openrouter.R  home provider; delete at work
outputs/              everything the scripts write
```

Paths are built with `here::here("unga", ...)`, so the hot_topic repo root is the project root. If unga becomes its own repo, change `p_in()` and `p_out()` in `unga_source.R`.

## topics.qmd

Render once with `run_searchK = TRUE` to choose K, set `K`, then render normally. Year enters prevalence as a spline. Country is not in the model; it is carried in `paragraph_theta.parquet` for filtering. Not every country speaks every year, so a topic trend mixes change within countries with change in who spoke.

The first render drafts `topic_codebook.csv` with one call per topic. Edit it by hand; it is never redrafted while it exists.

Outputs: `paragraph_theta.parquet`, `topic_summary.parquet`, `topic_trends.parquet`, `topic_codebook.csv`, `stm_fit.rds`, `manifest.csv`.

## stance.R

Edit `st` at the top and source the file. Always one topic, then either:

- `by = "country"`: one country, all its years. Gives a trend in year.
- `by = "year"`: one year, all countries. Gives a single estimate.

The `n` paragraphs (default 300) with the highest share of the topic are coded favor, neutral, oppose, or irrelevant, one call each. If the filter holds fewer than `n`, all are coded.

Writes to `outputs/stance/topic_NN/`:

- `NAME_BY_VALUE.parquet`: the coded paragraphs, enough to redraw any figure.
- `NAME_BY_VALUE_meta.rds`: claim, topic and label, filter, model, prompt, date, counts, the theta range of the selection, how many paragraphs fall after `model_cutoff_year`, the shares with 95% intervals clustered by speech, and the trend (country runs only).

Labels are saved after every window, so an interrupted run resumes without re-sending. If the claim, model, or topic model changes, the run stops and names the files to delete.

`run_stance(st)` and `plot_stance(res)` are plain functions. Sourced at top level the file runs; sourced inside a function with `local = TRUE` (as a Shiny server would) it only defines them.

For a host with no limits: `window_wait = 0`, `window_n` and `rpm` above `n`, `max_active` 40.

## What the numbers mean

- **Top n by topic share is not a random sample.** Shares describe the paragraphs most central to the topic, not every paragraph that touches it. `theta_range` in the meta file shows how far down the selection reached; paragraphs with a low share mostly come back irrelevant and drop out of the stance share.
- **Labels come from one model with no human check**, so label error is not in any interval. Read the coded paragraphs before trusting a number.
- **The stance model has not seen speeches after `model_cutoff_year`.** Earlier speeches may be in its training data. Comparing a country's pattern before and after the cutoff is a check that it reads the text rather than recalling it.
- **Trends are fitted only at years with coded paragraphs**, so a year a country did not speak is never drawn as observed. Where the rug thins, the line is mostly smoothing.

## Packages

tidyverse, here, arrow, stm, tidytext, splines, viridis, furrr, withr, glue, knitr, ellmer (0.4 or later).
