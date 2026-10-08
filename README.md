# Hot Topic

![](images/hot_topic_logo.svg)

Two tools over the same kind of text, each with its own scripts, its own Shiny app, and its own deployment, and a third project that applies both to UN General Assembly speeches.

```         
topics/   what a corpus is written about, and how that changes over time   (app)
stance/   where writers stand on one claim, in any corpus a user uploads  (app)
unga/     both methods on UNGA speeches: topics, then stance in one slice (scripts)
```

`topics/` fits a model once and serves the result; `stance/` calls a language model on every run and holds its R process while it does. Keeping them apart means a stance run cannot freeze the topics dashboard, and either app can be deployed, restarted, or taken down without the other. `unga/` has no functions of its own: it sources `topics/topics_source.R` and `stance/R/stance_core.R`, so its numbers mean what they mean in the apps.

Each folder has the same shape:

```         
<project>/
  app.R           the Shiny app (topics, stance)
  *.qmd, *.R      the scripts; the .qmd files are also the method reports
  *_source.R      shared functions for the scripts
  R/              the app's own functions
  inputs/         raw data you put there; not tracked by git
  outputs/        everything the scripts write; the topics app reads from here
```

The shared paths come from `options(hot_topic.project = ...)`, which every script sets before sourcing, so `p_in()` and `p_out()` point at the right folder.

## topics/

```         
topics/preprocess.qmd   comments -> paragraph units
topics/topics.qmd       paragraph units -> STM topics, codebook, prevalence trends
topics/app.R            dashboard: topics, and the paragraphs behind them
```

| Step | What to set | Model calls |
|----|----|----|
| 1\. `preprocess.qmd` | your corpus read, `min_tokens`, `max_tokens` | one embedding request per comment, first run only |
| 2\. `topics.qmd` | `K` (after one `run_searchK` pass) | one per topic, first run only |
| 3\. `app.R` | nothing | none |

1.  **preprocess.qmd.** Put your corpus in `topics/inputs/` and replace the corpus chunk with your own read (`p_in("YOUR_FILE.csv")`). It needs three columns: `atom_id` (comment id), `Year` (integer), `body_english` (text). Later renders reuse `embeddings.parquet` and make no calls.
2.  **topics.qmd.** Render once with `run_searchK = TRUE` to choose K, set `K`, then render normally. Render once with `run_sensitivity = TRUE` to check that the merge settings do not drive the topics. The first full render drafts `topic_codebook.csv`; edit it by hand, as it is never redrafted while the file exists.
3.  **app.** `shiny::runApp("topics")` from the repo root. Three tabs: **Start here** (what the data is, with descriptives and links to the method reports), **Topics** (prevalence over time, assignment sharpness, the codebook), **Read** (the paragraphs behind a topic, with the whole comment on click, and CSV downloads).

`topics_source.R` holds the shared functions. `llm_openrouter.R` is the home provider for embeddings and the codebook, and is deleted at work.

### How paragraph units are built

Most comments break after every sentence, which leaves orphan sentences too short for a topic model. `preprocess.qmd`:

1.  splits at line breaks, and rejoins wrapped lines (a line that follows a line without end punctuation and starts lowercase);
2.  embeds each comment, one request per comment, `window_n` per minute;
3.  within each comment, repeatedly merges the most similar pair of neighboring blocks, as long as one of them is under `min_tokens`, the result stays within `max_tokens`, and their similarity is above the `min_sim_quantile` point of all neighboring pairs in the corpus;
4.  drops units still under `min_tokens` and writes them to `dropped_units.csv`.

`min_tokens` is enough text for the topic model to read; `max_tokens` is the point past which a unit starts holding more than one subject. Those two numbers are the balance to tune. The similarity threshold is a quantile rather than a fixed cosine, so it means the same thing with any embedding model.

Read the dropped share, overall and by year, in the render. If it is large or concentrated in some years, loosen the settings: those years then rest on the longer, better formed comments.

### topics/outputs/

| File | Written by | What |
|----|----|----|
| `paragraphs.csv` | preprocess | the paragraph units, one row each |
| `dropped_units.csv` | preprocess | units too short to place, for review |
| `blocks.csv`, `embeddings.parquet`, `merge_settings.parquet` | preprocess | inputs to the sensitivity test |
| `paragraph_theta.csv` | topics | units with topic shares, assigned topic, theta |
| `topic_summary.csv` | topics | per-topic words, prevalence, AvePP |
| `topic_trends.csv` | topics | estimated topic share by year with intervals |
| `topic_codebook.csv` | topics | labels, descriptions, propositions (edit by hand) |
| `stm_fit.rds` | topics | the fitted model, reloaded on later renders |
| `searchK.parquet`, `sensitivity.parquet` | topics | diagnostics, computed once |
| `manifest.csv` | both | which inputs each cache was built from |

The app reads only the four CSVs: `paragraph_theta.csv`, `topic_codebook.csv`, `topic_summary.csv`, `topic_trends.csv`. It never fits a topic model and never writes to disk.

## stance/

```         
stance/stance.qmd   one claim over one corpus, with the method written out
stance/app.R        upload a CSV, write a claim, get labels and estimates
```

The app takes a user's own CSV: they point at the text column, optionally at a time column and a document column, write a claim, and every row is coded. They download their file with a `stance` column added, the estimates, and a sheet of 400 passages to code by hand as a check. Nothing is written to the server's disk and nothing is read from `outputs/`.

`shiny::runApp("stance")` from the repo root. Three pages: **Start here** (how to prepare a file, what the tool has been tried on, and what it does not measure), **Detect stance** (the run), **Check the labels** (hand codes in, agreement out).

To run the documented version over a corpus: put the CSV in `stance/inputs/`, name it and its columns in the config chunk at the top of `stance.qmd`, write the claim, and render. For the topics corpus, that CSV is `topics/outputs/paragraph_theta.csv`. Rendering also writes `stance/stance.pdf`, which both apps link to.

### How stance is measured

Every passage is coded; nothing is sampled.

1.  **Code.** Each passage goes alone to the model named by `STANCE_URL` and `STANCE_MODEL`, one request at a time, at temperature 0, without its date or its document. The reply is one of favor, neutral, oppose, or irrelevant (does not address the claim). The first passage is a probe: if the model cannot be reached, the run stops at once with the reason.
2.  **Estimate.** Four quantities, because a share of all passages confounds two different things:

$$P(\text{favor}) = P(\text{addresses}) \times P(\text{favor} \mid \text{addresses})$$

- **Salience** is the share of *all* passages that address the claim. It says whether the claim is live.
- **Favor, neutral, oppose** are shares of the passages that *do* address it. They say which way.

Reported together they separate a rise in agreement from a rise in attention. The cost is that the direction estimates rest on a smaller base that moves over time, so each basis gets its own period set and the app reports what was dropped.

Each quantity is a logistic regression on a natural spline in time with 95 percent intervals clustered by document; static shares get their intervals on the same logit scale, so they stay inside 0 to 100 percent without clipping. The plots draw each period's observed share under the curve, sized by the passages behind it. **A period needs at least 30 passages to appear in a trend, and a trend needs at least 4 such periods; otherwise time is dropped and the estimate is static.** Thin periods leave the trend but stay in the static estimate. With no time column the estimate is static from the start.

Only passages between 5 and 250 words are coded. Rows outside the bounds are reported and left uncoded. Those bounds guard against the wrong unit of text; the tested range is much narrower (paragraphs of roughly 50 to 80 tokens).

A time column may be a numeric year, `YYYY-MM`, or a date. Months become `year + (month - 1) / 12`, so one unit of time is one year either way.

`stance.qmd` saves labels every `save_every` passages and resumes where it stopped. The app keeps nothing: it shows the estimates and offers them as a CSV that records the claim, the full prompt, the model, the endpoint, the counts, and the date.

### stance/outputs/ (written by stance.qmd only)

| File | What |
|----|----|
| `stance_labels_NAME.csv` | one label per coded row, keyed by row number |
| `stance_estimates_NAME.csv` | the estimates with the claim, prompt, model, counts, date |
| `stance_prompt_NAME.txt` | the exact prompt and model that produced those labels |
| `stance_handcode_NAME.csv` | 400 passages drawn at random, with no model label |
| `manifest.csv` | which inputs each saved file was built from |

### Checking the labels

The intervals treat the labels as correct. Nothing in the pipeline measures how often they are not. Code 400 passages by hand without seeing the model's label, upload them, and read agreement, Cohen's kappa (both with bootstrap intervals over documents), and the confusion matrix. 400 puts agreement within about 5 points; it says little about a label the model rarely uses, so the per-label rows carry their counts and are marked thin under 30 cases.

## unga/

```         
unga/topics.qmd   UNGA paragraphs -> STM topics, codebook, prevalence trends
unga/stance.R     one claim, one topic, then one country (trend) or one year (static)
```

The paragraphs are already clean units, so there is no preprocessing step. `stance.R` codes every paragraph of the chosen topic inside the filter, with the stance app's own functions. Because a country gives one speech a year, its trend rule counts speeches rather than passages: a year counts with one paragraph, and a trend needs 10 speeches. The plots mark the stance model's training cutoff, since 2026 speeches are the ones it cannot have seen. Details in [unga/README.md](unga/README.md).

## Running at home

Both stance scripts and the stance app read three environment variables at run time. For a home test, put them in a `.Renviron` in the repo root (it is gitignored) and restart R:

```         
OPENROUTER_API_KEY=sk-or-v1-...
STANCE_URL=https://openrouter.ai/api/v1
STANCE_MODEL=google/gemma-4-31b-it
STANCE_KEY=${OPENROUTER_API_KEY}
```

R expands `${...}` from variables already set, which includes lines above it in the same file; an undefined name becomes empty without warning, and the first request then fails with a 401. For a local Ollama model, use `STANCE_URL=http://localhost:11434/v1`, the tag `ollama list` shows as `STANCE_MODEL`, and leave `STANCE_KEY` empty. `stance/try_stance_local.R` does the same thing for one session without a file, then starts the app.

## Settings

`manifest.csv` records the md5 of every input a cache was built from. If an input changes, the next render stops and names the file to delete, so a stale result is never reloaded.

Each script's `steps` table holds the **names** of `.Renviron` variables, never keys:

```         
COMPASS_EMBED_URL / COMPASS_EMBED_KEY   embeddings (preprocess)
COMPASS_LARGE_URL / COMPASS_LARGE_KEY   codebook (topics)
```

Stance needs no key at work: set `STANCE_URL` and `STANCE_MODEL` in `.Renviron` for `stance.qmd`, and as environment variables on Connect for the app. `STANCE_KEY` is read if set and sent as a bearer token, for a provider that needs one at home; it is never written into a result. At work, set `use_openrouter = FALSE` in `topics/preprocess.qmd`, `topics/topics.qmd` and `unga/topics.qmd`, and delete `topics/llm_openrouter.R` and `stance/try_stance_local.R`.

Deployment settings, read at startup:

``` r
# both apps
options(drsvyr.classification = "YOUR MARKING")   # the banner above every tab
# topics
options(hot_topic.source = "public comments submitted to ...")
options(hot_topic.docs = "https://github.com/klinares/hot_topic/blob/main")
options(hot_topic.stance_app = "https://connect/.../stance")  # adds a link to it
# stance
options(stance.tested = "English paragraphs from public comments, ...")
options(stance.docs = "https://github.com/klinares/hot_topic/blob/main/stance/stance.pdf")
options(stance.max_rows = 10000)        # largest file the app will code
options(stance.sec_per_passage = 0.1)   # measured rate, for the time estimate
```

Unset, the banner reads UNCLASSIFIED and the topics text says "public comments". `HOT_TOPIC_DATA` points the topics app at another data folder.

On Posit Connect:

- publish `topics/` as `app.R` + `R/` + `outputs/`, and `stance/` as `app.R` + `R/`. Uncheck `inputs/`, the `.qmd` files and the PDFs in the publish dialog; they are not needed to serve either app.
- for the stance app, set `STANCE_URL` and `STANCE_MODEL`, and set **Max connections per process** to 1: a run holds its R process for as long as it takes, and this keeps it from freezing other users.
- plots use Cairo (`options(bitmapType = "cairo")` in both `app.R` files), since the server has no X11.

## Packages

Scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, withr, httr2, ellmer (0.4 or later; the embedding and codebook steps only), knitr, glue, arrow; quanteda only for the demo corpus.

Apps: shiny, bslib, ggplot2, dplyr, purrr, readr, tibble, withr, splines, httr2; topics also DT, stringr, viridisLite, glue.

## What the numbers do not include

- **Topic assignment is an estimate.** Each paragraph goes to its most likely topic; AvePP says how cleanly. Entropy R² and AvePP both fall as units get longer, because longer units genuinely mix topics, so use them to compare topics within a fit, not to choose the unit size.
- **Stance labels come from one model**, so label error is not in any interval unless you run the hand-coded check. Read the example passages the render prints before trusting a number, and re-run with a paraphrase of the claim to see whether the result turns on its wording.
- **Every share is a share of passages**, so a long document counts more than a short one. These are not shares of writers.
- **Nothing is weighted.** Both tools describe the corpus in front of them, not a wider population.
- **Trends are smoothed.** Where a period holds few passages, the line is mostly the model interpolating; periods under the threshold are left out rather than drawn.

## Troubleshooting

| Message | Meaning |
|----|----|
| `X changed since Y was built. Delete Y` | an upstream file changed; delete Y and re-render |
| `N comments could not be embedded. First error: ...` | the provider's own message; re-render, embedded comments are not re-sent |
| `The model could not be reached or did not answer: ...` | check `STANCE_URL`, `STANCE_MODEL`, and that the server can reach the endpoint |
| `N passages got no label; re-render to retry them` | the successes are saved; re-render sends only the rest |
| `Set X and Y in .Renviron` / `Set STANCE_URL and STANCE_MODEL` | the named variable is empty; restart R after editing .Renviron |
| `ellmer 0.4.0 or later is needed` | update ellmer (the key is passed as `credentials`) |
| `stm_fit.rds has K = a but tx$K = b` | delete `stm_fit.rds` |
| `sensitivity.parquet` was built at another K | delete `sensitivity.parquet` |
| stance: `X: no trend, N period(s) with at least 30 passages` | not enough dense periods; read the static estimate instead |
| stance: `separation: the label is (nearly) certain over part of the range` | that quantity is almost constant; read its overall share |
| stance: `The time column must be numeric (a year), "YYYY-MM", or a date` | pick another column, or none |
| unga: `No paragraph of topic K with country = X` | check the spelling of the country as it is in the data, or pick another topic |
| request fails with HTTP 401 at home | `STANCE_KEY` is empty; see Running at home |
| app: `could not find function "load_outputs"` | the helper files are not in `R/`, or the app was started from the wrong folder |
