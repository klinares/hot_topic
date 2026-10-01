# Hot Topic

![](images/hot_topic_logo.svg)

What people write about in a corpus of public comments, how that changes over time, and where they stand on a claim. Three Quarto scripts and a Shiny dashboard.

```         
code/preprocess.qmd   comments -> paragraph units
code/topics.qmd       paragraph units -> STM topics, codebook, prevalence trends
code/stance.qmd       one claim -> stance and attention trends (experimental)
app/                  dashboard over the topics outputs
outputs/              everything the scripts write; the app reads from here
```

`code/llm_source.R` holds every shared function. `code/llm_openrouter.R` is the home provider and is deleted at work.

Topics and stance are independent. Topics answer "what is written about"; stance answers "where do writers stand on this claim". Stance reads only the preprocess outputs, so a claim can be measured whether or not it matches a topic.

## Run order

| Step | What to set | Model calls |
|------------------------|------------------------|------------------------|
| 1\. `preprocess.qmd` | your corpus read, `min_tokens`, `max_tokens` | one embedding request per comment, first run only |
| 2\. `topics.qmd` | `K` (after one `run_searchK` pass) | one per topic, first run only |
| 3\. `stance.qmd` | `name`, `proposition`, `negation` | 2 embeddings, plus the coding budget |
| 4\. `app/` | nothing | none |

1.  **preprocess.qmd.** Replace the corpus chunk with your own read. It needs three columns: `atom_id` (comment id), `Year` (integer), `body_english` (text). Later renders reuse `embeddings.rds` and make no calls.
2.  **topics.qmd.** Render once with `run_searchK = TRUE` to choose K, set `K`, then render normally. Render once with `run_sensitivity = TRUE` to check that the merge settings do not drive the topics. The first full render drafts `topic_codebook.csv`; edit it by hand, as it is never redrafted while the file exists.
3.  **stance.qmd.** Write the claim, its negation, and a short `name` for its files. Each claim keeps its own labels, so several claims coexist in `outputs/`.
4.  **app.** `shiny::runApp("app")` from the repo root.

## How paragraph units are built

Most comments break after every sentence, which leaves orphan sentences too short for a topic model. `preprocess.qmd`:

1.  splits at line breaks, and rejoins wrapped lines (a line that follows a line without end punctuation and starts lowercase);
2.  embeds each comment, one request per comment, `window_n` per minute;
3.  within each comment, repeatedly merges the most similar pair of neighboring blocks, as long as one of them is under `min_tokens`, the result stays within `max_tokens`, and their similarity is above the `min_sim_quantile` point of all neighboring pairs in the corpus;
4.  drops units still under `min_tokens` and writes them to `dropped_units.csv`.

`min_tokens` is enough text for the topic model to read; `max_tokens` is the point past which a unit starts holding more than one subject. Those two numbers are the balance to tune. The similarity threshold is a quantile rather than a fixed cosine, so it means the same thing with any embedding model.

Read the dropped share, overall and by year, in the render. If it is large or concentrated in some years, loosen the settings: those years then rest on the longer, better formed comments.

## How stance is measured

Coding every paragraph would cost one call each. Instead `stance.qmd` uses **two-phase stratified sampling**:

1.  **Score.** The claim and its negation are embedded with the corpus model (2 calls). Each paragraph takes the higher of its two cosines, so paragraphs arguing against the claim in their own words rank as high as ones echoing it. Paragraph vectors come from `preprocess.qmd`, so nothing is re-embedded.
2.  **Stratify.** Paragraphs are ranked by that score into high, middle and low strata. A sample is drawn from each, heavier where the claim is likely, never zero anywhere. Unused calls roll down to the next stratum, so the whole budget is spent.
3.  **Code.** One call per sampled paragraph returns favor, neutral, oppose, or irrelevant.
4.  **Weight.** Each coded paragraph carries the weight N/n of its stratum, so estimates describe the whole corpus, not only the paragraphs that were read.

Two lines come out, both with intervals clustered by comment:

- **stance**: the share of paragraphs addressing the claim that favor it.
- **attention**: the share of all paragraphs that address the claim at all.

Read them together. A change in stance with flat attention is a change of opinion; a change in attention with flat stance is a change in what gets discussed.

**The low stratum is the audit.** Its relevance rate, printed in the labels table, is the share of low-similarity paragraphs that turned out relevant. A low value means the similarity screen missed little. A high value means it missed a lot, those paragraphs carry heavy weights, and every interval widens; the fix is to move budget from `high` to `low` in `st$n`.

## Rate limits and budget

The coding loop is built around quota windows, and every limit is a setting. Nothing in the code assumes one provider.

``` r
window_n   = 300L   # calls per window: the most one quota window allows
window_wait = 60L   # seconds to rest between windows
rpm        = 300L   # requests a minute ellmer may start
max_active = 10L    # simultaneous connections
n = c(high = 200L, mid = 70L, low = 30L)   # coding budget per stratum
```

| Host | Settings |
|------------------------------------|------------------------------------|
| 300 calls per 4 hours | `window_n = 300`, `window_wait = 4 * 3600`, `rpm = 300` |
| 500 a minute | `window_n = 500`, `window_wait = 60`, `rpm = 500` |
| no token or rate limit | `window_wait = 0`, `window_n` and `rpm` above the budget, `max_active` 40 or more |

Labels are saved after every window, so a run that is interrupted, crashes, or waits four hours resumes where it stopped and re-sends nothing.

**With no limits, code the census.** Set every entry of `n` above the corpus size. Every paragraph is coded, all weights become 1, sampling error disappears, and only label error remains. The strata table then shows `weight` 1 throughout. At `max_active = 40`, a thousand paragraphs take well under a minute.

## Outputs (all in outputs/)

| File | Written by | What |
|------------------------|------------------------|------------------------|
| `paragraphs.csv` | preprocess | the paragraph units, one row each |
| `dropped_units.csv` | preprocess | units too short to place, for review |
| `blocks.csv`, `embeddings.rds`, `merge_settings.rds` | preprocess | inputs to the sensitivity test |
| `paragraph_vectors.rds` | preprocess | one vector per paragraph, for stance similarity |
| `paragraph_theta.csv` | topics | units with topic shares, assigned topic, theta |
| `topic_summary.csv` | topics | per-topic words, prevalence, AvePP |
| `topic_trends.csv` | topics | estimated topic share by year with intervals |
| `topic_codebook.csv` | topics | labels, descriptions, propositions (edit by hand) |
| `stm_fit.rds`, `searchK.rds`, `sensitivity*.{rds,csv}` | topics | model caches |
| `stance_labels_NAME.csv` | stance | one row per coded paragraph, with its stratum and weight |
| `stance_trend_NAME.csv` | stance | both fitted lines |
| `stance_prompt_NAME.txt` | stance | the exact prompt that produced those labels |
| `manifest.csv` | all | which inputs each cache was built from |

`manifest.csv` records the md5 of every input a cache was built from. If an input changes, the next render stops and names the file to delete, so a stale model is never reloaded.

## The app

Three tabs: **Start here** (what the data is, with descriptives), **Topics** (prevalence over time, assignment sharpness, the codebook), **Read** (the paragraphs behind a topic, with the whole comment on click, and CSV downloads).

It reads `paragraph_theta.csv`, `topic_codebook.csv`, `topic_summary.csv` and `topic_trends.csv` straight from `outputs/`, and never fits anything.

Two deployment settings, both read at startup:

``` r
options(drsvyr.classification = "YOUR MARKING")   # the banner above every tab
options(hot_topic.source = "public comments submitted to ...")  # names the text on Start here
```

Unset, the banner reads UNCLASSIFIED and the text says "public comments". Posit Connect deploys only `app/`, so `../outputs/` is not there: set `HOT_TOPIC_DATA` to a folder the server can read, or copy the four files into `app/data/` and set `HOT_TOPIC_DATA=data`.

## Settings for work

Each script's `steps` table holds the **names** of `.Renviron` variables, never keys:

```         
COMPASS_EMBED_URL / COMPASS_EMBED_KEY   embeddings (preprocess, stance)
COMPASS_LARGE_URL / COMPASS_LARGE_KEY   codebook (topics)
COMPASS_SMALL_URL / COMPASS_SMALL_KEY   stance coding
```

Set `use_openrouter = FALSE` in all three scripts and delete `llm_openrouter.R`. Stance must use the same `embed` row as preprocess, or the claim is embedded with a different model than the corpus and the render stops.

## Packages

Scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, withr, httr2 (1.1 or later), ellmer (0.4 or later), knitr, glue; quanteda only for the demo corpus.

App: shiny, bslib, DT, ggplot2, viridisLite, dplyr, purrr, readr, stringr, tibble.

## What the numbers do not include

- **Topic assignment is an estimate.** Each paragraph goes to its most likely topic; AvePP says how cleanly. Entropy R² and AvePP both fall as units get longer, because longer units genuinely mix topics, so use them to compare topics within a fit, not to choose the unit size.
- **Stance labels come from one model with no human check**, so label error is not in any interval. Read the example paragraphs the render prints before trusting a number, and re-run with a paraphrase of the claim to see whether the result turns on its wording.
- **Every share is a share of paragraphs**, so a long comment counts more than a short one. These are not shares of commenters.
- **Trends are smoothed.** Where the tick marks under a stance line thin out, the line is mostly the model interpolating.

## Troubleshooting

| Message | Meaning |
|------------------------------------|------------------------------------|
| `X changed since Y was built. Delete Y` | an upstream file changed; delete Y and re-render |
| `N comments could not be embedded. First error: ...` | the provider's own message; re-render, embedded comments are not re-sent |
| `Every call in the window failed. First error: ...` | the provider's own message; nothing was saved for that window |
| `N calls failed; re-render to retry them` | partial failure; the successes are saved, re-render sends only the rest |
| `Set X and Y in .Renviron` | the named variable is empty; restart R after editing .Renviron |
| `ellmer 0.4.0 or later is needed` | update ellmer (the key is passed as `credentials`) |
| `stm_fit.rds has K = a but tx$K = b` | delete `stm_fit.rds` |
| `The claim was embedded with a different model` | stance's `embed` row differs from preprocess's |
| stance: `no trend fitted: too few paragraphs` | under `min_class_n` on one side; raise the budget in `n` or read the shares only |
| app: `could not find function "load_outputs"` | the four helper files are not in `app/R/`, or the app was started from the wrong folder |
