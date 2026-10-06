# unga

Topics in UN General Assembly speeches, how they change over time, and stance toward a claim within one topic. It runs the topics project's method on a corpus that needs no preprocessing, then the stance project's method on one slice of it.

```         
unga/inputs/unga.parquet   id, para_id, year, country, raw_text (one row per paragraph)
unga/topics.qmd            step 1: STM topics, codebook, prevalence trends
unga/stance.R              step 2: stance on one claim, one topic, one country or one year
unga/outputs/              everything both steps write
```

There is no code of its own beyond these two scripts. `topics.qmd` uses `topics/topics_source.R` and `stance.R` uses `stance/R/stance_core.R` as well, so a topic or a stance estimate here means exactly what it means in those projects, and a fix there reaches here. Each script sets `options(hot_topic.project = "unga")` before sourcing, which points the shared paths at `unga/inputs` and `unga/outputs`. If unga ever becomes its own repo, copy those two files with it.

## topics.qmd

The paragraphs are already clean units: `id` is the speech, `para_id` the paragraph within it. There is no embedding or merging step.

Render once with `run_searchK = TRUE` to choose K, set `K`, then render normally. Year enters prevalence as a spline. Country is not in the model; it is carried in `paragraph_theta.parquet` for filtering. Not every country speaks every year, so a topic trend mixes change within countries with change in who spoke.

`drop_words` removes the boilerplate every speech shares (united, nations, assembly, ...), which would otherwise load on every topic.

The first render drafts `topic_codebook.csv` with one call per topic. Edit it by hand; it is never redrafted while it exists.

Outputs: `paragraph_theta.parquet`, `topic_summary.parquet`, `topic_trends.parquet`, `topic_codebook.csv`, `stm_fit.rds`, `searchK.parquet` (when run), `manifest.csv`.

Trend intervals refit the prevalence model on `n_draws` draws of every paragraph's topic shares, so memory grows with draws × paragraphs × K. On a corpus of hundreds of thousands of paragraphs, lower `n_draws` before raising anything else.

## stance.R

Edit `st` at the top and source the file. Always one topic, then either:

-   `by = "country"`: one country, all its years. Gives a trend in year.
-   `by = "year"`: one year, all countries. Gives a static estimate.

**Every** paragraph whose most likely topic is `st$topic` inside that filter is coded, one request at a time, by the model named in `STANCE_URL` and `STANCE_MODEL`. Nothing is sampled. The estimates are the stance app's:

-   **salience**: the share of the topic's paragraphs that address the claim;
-   **favor, neutral, oppose**: shares of the paragraphs that do address it.

Intervals are 95 percent and clustered by speech.

**The trend rule is different from the stance app's, on purpose.** The app needs 30 passages in a period because a period there holds many documents. Here a country gives one speech a year, so the speech is the unit: a year counts with a single paragraph on the topic (`min_period_n = 1`), and the trend needs at least 10 such speeches (`min_periods = 10`), because the intervals rest on the number of speeches. With fewer, the result is static.

Writes to `unga/outputs/stance/`, named `NAME_topicK_BY_VALUE`:

| File | What |
|------------------------------------|------------------------------------|
| `_labels.parquet` | one label per paragraph; the run resumes from it |
| `_prompt.txt` | the exact prompt and model behind those labels |
| `_estimates.csv` | the estimates, with topic, filter, claim, prompt, model, counts, paragraphs after the cutoff, and date |

Labels are saved every `save_every` paragraphs. If the claim, the model, or the topic model changes, the run stops and names the file to delete.

`run_stance(st)` and `plot_stance(res)` are plain functions. Sourced at top level the file runs; sourced with `local = TRUE` (as a Shiny server would) it only defines them.

## What the numbers mean

-   **The slice is a topic, then a filter.** A paragraph belongs to the topic it is most about. A paragraph that touches the claim but is mostly about something else is not in the slice, so salience is "of the paragraphs on this topic", not "of everything the country said".
-   **2026 is at the edge of the curve.** The stance model has not seen speeches after `model_cutoff_year`, which makes 2026 the year to trust most for reading rather than recall, and also the year a spline estimates worst, because it leans on the years before. The plots draw each year's observed share under the curve; for the 2026 number itself, run `by = "year", value = 2026`.
-   **The dotted line is the model's cutoff.** A pattern that holds on both sides of it is being read from the text; one that breaks at the line may be the model remembering speeches it was trained on.
-   **Labels come from one model.** Their error is not in any interval. Read the coded paragraphs, and hand-code a random sample of them before reporting a number; `stance_agreement()` in `stance_core.R` gives agreement, kappa, and the confusion matrix from the two sets of labels.
-   **Long paragraphs are left out.** Paragraphs over `max_words` are reported and not coded. If a filter loses many, raise it and say so.
-   **Nothing is weighted.** Estimates describe the speeches given, not the countries that did not speak.

## Packages

tidyverse, here, arrow, stm, tidytext, splines, viridis, furrr, withr, glue, knitr, httr2, ellmer (0.4 or later; the codebook only).
