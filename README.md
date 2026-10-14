# Hot Topic

![](images/hot_topic_logo.svg)

Two methods over the same kind of text: what a corpus is written about, and where writers stand on one claim. Each has its own scripts and its own Shiny app, deployed separately.

```         
topics/        what a corpus is written about, and how that changes over time  (scripts)
  unga/        the same method on UNGA General Debate speeches, 2000 to 2026    (script)
topics_app/    the dashboard for the topics results; moves to its own repo     (app)
stance/        where writers stand on one claim, in any corpus a user uploads  (scripts + app)
```

The topics scripts fit a model once, and the dashboard only reads what they saved. The stance app calls a language model on every run and holds its R process while it does. Keeping them apart means a stance run cannot freeze the topics dashboard, and either app can be deployed, restarted, or taken down without the other.

Each project folder has the same shape:

```         
<project>/
  *.qmd           the scripts; rendered, they are also the method reports
  *_source.R      shared functions for the scripts
  inputs/         raw data you put there; not tracked by git
  outputs/        everything the scripts write
```

`topics/unga/` has no functions of its own: it sources `topics/topics_source.R`, so its topics are estimated exactly as in `topics/topics.qmd`. The shared paths come from `options(hot_topic.project = ...)`, which each script sets before sourcing, so `p_in()` and `p_out()` point at its own `inputs/` and `outputs/`. `stance/` also holds its app (`app.R` and `R/`).

## topics/

```         
topics/preprocess.qmd   comments -> paragraph units
topics/topics.qmd       paragraph units -> STM topics, codebook, prevalence trends
```

| Step | What to set | Model calls |
|------------------------|------------------------|------------------------|
| 1\. `preprocess.qmd` | your corpus read, `min_tokens`, `max_tokens` | one embedding request per comment, first run only |
| 2\. `topics.qmd` | `K` (after one `run_searchK` pass) | one per topic, first run only |
| 3\. copy to `topics_app/` | nothing | none |

1.  **preprocess.qmd.** Put your corpus in `topics/inputs/` and replace the corpus chunk with your own read (`p_in("YOUR_FILE.csv")`). It needs three columns: `atom_id` (comment id), `Year` (integer), `body_english` (text). Later renders reuse `embeddings.parquet` and make no calls.
2.  **topics.qmd.** Render once with `run_searchK = TRUE` to choose K, set `K`, then render normally. Render once with `run_sensitivity = TRUE` to check that the merge settings do not drive the topics: the units are rebuilt at 0.75 and 1.25 times the token settings and refit with the same K and year spline, and each topic is matched to its closest refit topic. The first full render drafts `topic_codebook.csv`; edit it by hand, as it is never redrafted while the file exists.
3.  **app.** Copy the four CSVs the app reads into `topics_app/outputs/` and the rendered `topics.pdf` (and `preprocess.pdf`) into `topics_app/www/`. See below.

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
|------------------------|------------------------|------------------------|
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

The app reads only the four CSVs: `paragraph_theta.csv`, `topic_codebook.csv`, `topic_summary.csv`, `topic_trends.csv`. `stm_fit.rds` is small for this corpus and tracked; for UNGA it is not (below).

## topics_app/

The dashboard for the topics results, built to become its own repository. It reads the four CSVs from its own `outputs/` and the method report PDFs from `www/`, never fits a model, and never writes to disk. `shiny::runApp("topics_app")` from the repo root.

Three tabs: **Start here** (what topic modeling is, why it is used and what it offers, a flowchart of how the results were made, how to use the tool, how to read the numbers, a summary of the data, and links to each PDF found in `www/`), **Topics** (one topic's words, label, trend with its interval, and exact counts, beside every topic), and **Read** (the paragraphs behind a topic, the whole document on click, CSV downloads). The classification banner sits at the top with the office logo below it; until `www/logo.png` exists, a dashed box marks its place. Settings are in one block at the top of `app.R`. Details in [topics_app/README.md](topics_app/README.md).

`paragraph_theta.csv` holds the text of every paragraph; commit it to the app's repository only if that text may be stored there.

## stance/

```         
stance/stance.qmd   one claim over one corpus, with the method written out
stance/app.R        upload a CSV, write a claim, get labels and estimates
```

The app takes a user's own CSV: they point at the text column, optionally at a time column and a document column, write a claim, and every row is coded. They download their file with a `stance` column added, the estimates, and a sheet of 400 passages to code by hand as a check. There is no limit on the number of rows. Nothing is written to the server's disk and nothing is read from `outputs/`.

`shiny::runApp("stance")` from the repo root. Three pages: **Start here** (what the method is and why, how to use the tool and shape a file for it, a flowchart, and how to write a claim, following Li and Conrad 2024), **Detect stance** (the run and the three downloads), **Check the labels** (the labeled file and the coded sheet in, agreement out).

**The check is stateless.** Every file of a run carries the same run id (`stance_run`, e.g. `run-20261013-180601-1f3a`) and row number (`stance_row`). An analyst can download the files, code the sheet over days, and come back to a new session: Check the labels takes the labeled file and the coded sheet, refuses them if their run ids differ, and matches the rows. Sorting or re-saving either file in a spreadsheet does not break the match. Both are written as UTF-8 with a byte-order mark so a spreadsheet opens them cleanly.

To run the documented version over a corpus: put the CSV in `stance/inputs/`, name it and its columns in the config chunk at the top of `stance.qmd`, write the claim, and render. For the topics corpus, that CSV is `topics/outputs/paragraph_theta.csv`. Rendering also writes `stance/stance.pdf`, which the stance app links to.

### How stance is measured

Every passage is coded; nothing is sampled.

1.  **Code.** Each passage goes alone to the model set by `stance.url` and `stance.model`, one request per passage, `stance.workers` requests at a time, at temperature 0, without its date or its document. Requests go out in chunks of ten per worker, so the progress bar moves during a parallel run; each passage is still its own request, so the labels do not depend on how many run at once (needs httr2 1.1.1 or later). Identical passages are sent once and the label copied to every copy; each copy still counts as its own passage in the estimates, so a form letter sent by 500 people counts 500 times. The reply is one of favor, neutral, oppose, or irrelevant (does not address the claim). The first passage is a probe: if the model cannot be reached, the run stops at once with the reason.
2.  **Estimate.** Four quantities, because a share of all passages confounds two different things:

$$P(\text{favor}) = P(\text{addresses}) \times P(\text{favor} \mid \text{addresses})$$

-   **Salience** is the share of *all* passages that address the claim. It says whether the claim is live.
-   **Favor, neutral, oppose** are shares of the passages that *do* address it. They say which way.

Reported together they separate a rise in agreement from a rise in attention. The cost is that the direction estimates rest on a smaller base that moves over time, so each basis gets its own period set and the app reports what was dropped.

Each quantity is a logistic regression on a natural spline in time with 95 percent intervals clustered by document; static shares get their intervals on the same logit scale, so they stay inside 0 to 100 percent without clipping. The plots draw each period's observed share under the curve, sized by the passages behind it. **A period needs at least 30 passages to appear in a trend, and a trend needs at least 4 such periods; otherwise time is dropped and the estimate is static.** Thin periods leave the trend but stay in the static estimate. With no time column the estimate is static from the start.

Only passages between 5 and 250 words are coded. Rows outside the bounds are reported and left uncoded. Those bounds guard against the wrong unit of text; the tested range is much narrower (paragraphs of roughly 50 to 80 tokens).

A time column may be a numeric year, `YYYY-MM`, or a date. Months become `year + (month - 1) / 12`, so one unit of time is one year either way.

`stance.qmd` saves labels every `save_every` passages and resumes where it stopped; `st$workers` sets its parallel requests. The app keeps nothing: it shows the estimates and offers them as a CSV that records the claim, the full prompt, the model, the endpoint, the counts, and the date.

### stance/outputs/ (written by stance.qmd only)

| File | What |
|------------------------|------------------------------------------------|
| `stance_labels_NAME.csv` | one label per coded row, keyed by row number |
| `stance_estimates_NAME.csv` | the estimates with the claim, prompt, model, counts, date |
| `stance_prompt_NAME.txt` | the exact prompt and model that produced those labels |
| `stance_handcode_NAME.csv` | 400 passages drawn at random, with no model label |
| `manifest.csv` | which inputs each saved file was built from |

### Checking the labels

The intervals treat the labels as correct. Nothing in the pipeline measures how often they are not. Code 400 passages by hand without seeing the model's label, upload them, and read agreement, Cohen's kappa (both with bootstrap intervals over documents), and the confusion matrix. 400 puts agreement within about 5 points; it says little about a label the model rarely uses, so the per-label rows carry their counts and are marked thin under 30 cases.

## topics/unga/

```         
topics/unga/topics.qmd   UNGA paragraphs -> STM topics, codebook, prevalence trends, findings
```

The paragraphs come already parsed from the speeches and are shared with other analyses, so they are never merged, split, or edited: a paragraph that is not one (headers, the presiding officer, fragments under 20 words) is left out whole, and every output joins back on `id` + `para_uid`. Stance is done in the stance app: filter `paragraph_topics.parquet`, join the text back, and upload. `stm_fit.rds` is too large for GitHub at this size (200 MB or more at K = 40) and is ignored; the parquet outputs are small and tracked. The first K search runs 5 and 10 to 100 by 10 on 4 workers, then a finer grid. Details in [topics/unga/README.md](topics/unga/README.md).

## Running at home

At home the model needs a key, which never goes in a script. Set `stance.url` and `stance.model` to `NULL` in `app.R` (and `url`, `model` in `stance.qmd`) so all three come from a `.Renviron` in the repo root (it is gitignored), then restart R:

```         
OPENROUTER_API_KEY=sk-or-v1-...
STANCE_URL=https://openrouter.ai/api/v1
STANCE_MODEL=google/gemma-4-31b-it
STANCE_KEY=${OPENROUTER_API_KEY}
```

R expands `${...}` from variables already set, which includes lines above it in the same file; an undefined name becomes empty without warning, and the first request then fails with a 401. For a local Ollama model, use `STANCE_URL=http://localhost:11434/v1`, the tag `ollama list` shows as `STANCE_MODEL`, and leave `STANCE_KEY` empty. `stance/try_stance_local.R` does the same thing for one session without a file, then starts the app.

`stance/test_gemma.R` was a one-off check of the stance code against Gemma; delete it and `stance/outputs/gemma_test_*`.

## Settings

`manifest.csv` records the md5 of every input a cache was built from. If an input changes, the next render stops and names the file to delete, so a stale result is never reloaded.

Each script's `steps` table holds the **names** of `.Renviron` variables, never keys:

```         
COMPASS_EMBED_URL / COMPASS_EMBED_KEY   embeddings (preprocess)
COMPASS_LARGE_URL / COMPASS_LARGE_KEY   codebook (topics)
```

Stance needs no key at work. Set the model in the scripts as strings and leave the key as `NULL`:

``` r
# stance/app.R
options(stance.url = "http://YOUR-GEMMA-HOST:8000/v1", stance.model = "YOUR-MODEL-NAME",
        stance.key = NULL)
# stance/stance.qmd, in the config list
url = "http://YOUR-GEMMA-HOST:8000/v1", model = "YOUR-MODEL-NAME", key = NULL,
```

A key is never typed into a script. A `NULL` key reads `STANCE_KEY` from `.Renviron` when it is set and otherwise sends none; a URL or model set to `NULL` reads `STANCE_URL` or `STANCE_MODEL`. The URL and model are written into every result; the key never is. At work, set `use_openrouter = FALSE` in `topics/preprocess.qmd`, `topics/topics.qmd` and `topics/unga/topics.qmd`, and delete `topics/llm_openrouter.R`, `stance/try_stance_local.R`, and `stance/test_gemma.R`.

Deployment settings, set at the top of each `app.R`:

``` r
# both apps
options(drsvyr.classification = "YOUR MARKING")   # the banner above every tab
# topics_app
options(hot_topic.logo = "logo.png")              # in www/; a placeholder until it exists
options(hot_topic.office = "")                    # office name beside the logo
options(hot_topic.source = "public comments submitted to ...")
options(hot_topic.unit = c("comment", "comments"))  # one document, and many
options(hot_topic.stance_app = "https://connect/.../stance")  # adds a link to it
# stance
options(stance.tested = "English paragraphs from public comments, ...")
options(stance.docs = "https://github.com/klinares/hot_topic/blob/main/stance/stance.pdf")
options(stance.workers = 4L)            # requests sent to the model at once (in app.R)
options(stance.sec_per_passage = 0.1)   # measured rate, for the time estimate
```

Unset, the banner reads UNCLASSIFIED and the topics text says "public comments". `HOT_TOPIC_DATA` points the topics app at another data folder.

On Posit Connect:

-   publish `topics_app/` as `app.R` + `R/` + `outputs/` + `www/`, and `stance/` as `app.R` + `R/`. Uncheck `inputs/`, the `.qmd` files and the PDFs in `stance/` in the publish dialog; they are not needed to serve the stance app.
-   for the stance app, set `stance.url` and `stance.model` in `app.R` before publishing, and set **Max connections per process** to 1: a run holds its R process for as long as it takes, and this keeps it from freezing other users.
-   plots use Cairo (`options(bitmapType = "cairo")` in both `app.R` files), since the server has no X11.

## Packages

Scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, withr, httr2, ellmer (0.4 or later; the embedding and codebook steps only), knitr, glue, arrow; quanteda only for the demo corpus.

Apps: shiny, bslib, ggplot2, dplyr, purrr, readr, tibble, withr, splines, httr2 (1.1.1 or later for parallel requests); topics also DT, stringr, viridisLite, glue.

## What the numbers do not include

-   **Topic assignment is an estimate.** Each paragraph goes to its most likely topic; AvePP says how cleanly. Entropy R² and AvePP both fall as units get longer, because longer units genuinely mix topics, so use them to compare topics within a fit, not to choose the unit size.
-   **Stance labels come from one model**, so label error is not in any interval unless you run the hand-coded check. Read the example passages the render prints before trusting a number, and re-run with a paraphrase of the claim to see whether the result turns on its wording.
-   **Every share is a share of passages**, so a long document counts more than a short one. These are not shares of writers.
-   **Nothing is weighted.** Both tools describe the corpus in front of them, not a wider population.
-   **Trends are smoothed.** Where a period holds few passages, the line is mostly the model interpolating; periods under the threshold are left out rather than drawn.

## Troubleshooting

| Message | Meaning |
|------------------------------------|------------------------------------|
| `X changed since Y was built. Delete Y` | an upstream file changed; delete Y and re-render |
| `N comments could not be embedded. First error: ...` | the provider's own message; re-render, embedded comments are not re-sent |
| `The model could not be reached or did not answer: ...` | check `stance.url` and `stance.model` (or `STANCE_URL`, `STANCE_MODEL`), and that the server can reach the endpoint |
| `N passages got no label; re-render to retry them` | the successes are saved; re-render sends only the rest |
| `Set X and Y in .Renviron` / `Set the model's URL and name` | the setting is empty; set it in the script, or restart R after editing .Renviron |
| `ellmer 0.4.0 or later is needed` | update ellmer (the key is passed as `credentials`) |
| `stm_fit.rds has K = a but tx$K = b` | delete `stm_fit.rds` |
| `sensitivity.parquet` was built at another K | delete `sensitivity.parquet` |
| stance: `X: no trend, N period(s) with at least 30 passages` | not enough dense periods; read the static estimate instead |
| stance: `separation: the label is (nearly) certain over part of the range` | that quantity is almost constant; read its overall share |
| stance: `The time column must be numeric (a year), "YYYY-MM", or a date` | pick another column, or none |
| `httr2 1.1.1 or later is needed to send requests in parallel` | update httr2 on the machine or server running it |
| check: `The two files come from different runs` | the labeled file and the sheet must come from the same run; download them together |
| check: `No row of the sheet has a hand_label yet` | the sheet was uploaded before it was coded, or the column was renamed |
| request fails with HTTP 401 at home | `STANCE_KEY` is empty; see Running at home |
| app: `could not find function "load_outputs"` | the helper files are not in `R/`, or the app was started from the wrong folder |
