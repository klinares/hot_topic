# Hot Topic

![](images/hot_topic_logo.svg)

Two questions asked of a large body of text, each answered by a method built to be explained and checked:

1. **What is it about, and how did that change?** Topic modeling finds the subjects without anyone listing them in advance and estimates each one's share of the text by year, with intervals.
2. **Where does it stand on a claim?** Stance detection codes every passage for or against one proposition and estimates both how much the text addresses the claim and which way it leans.

A language model helps at two points: it drafts names for the topics the statistical model found, and it codes stance. Neither step decides what the topics are or how much text they cover; that comes from the topic model.

```
topics/                 topic modeling
  topics_source.R       every function the topics projects use
  llm_openrouter.R      home models (not read at work)
  <project>/            one folder per corpus: its scripts, inputs/, outputs/, README
stance/                 stance detection: scripts, source, and app
```

Each topics project sets `options(hot_topic.project = "topics/<project>")` and sources `topics/topics_source.R`, so every corpus is modeled exactly the same way, and `p_in()` / `p_out()` point at that project's own `inputs/` and `outputs/`. Project specifics, including any app, are in each project's README.

## Topic modeling

### The model

A **structural topic model** (STM; Roberts, Stewart and Tingley) treats each paragraph as a mixture of topics and each topic as a distribution over words. Unlike plain LDA, STM lets a covariate shape how much each topic is discussed. Here that covariate is **year, entered as a natural spline**, so a topic's share can rise, peak and fade rather than follow a straight line. Spectral initialization makes a fit repeatable on the same machine.

The unit is the **paragraph**, not the document. A document often covers several subjects; a paragraph usually covers one, so its topic shares are sharper and easier to read.

### Building paragraphs from messy text

Some corpora arrive as clean paragraphs, and those are used exactly as parsed. Others, such as public comments, break after every sentence, leaving orphan sentences too short for a topic model. For those, `preprocess.qmd`:

1. splits at line breaks and rejoins wrapped lines;
2. embeds every block (requests pack up to `batch_size` blocks each, under the endpoint's input limit; each distinct text is embedded once, and a stopped run resumes);
3. within each document, repeatedly merges the most similar pair of **neighboring** blocks, while one is under `min_tokens`, the result stays within `max_tokens`, and their similarity clears the `min_sim_quantile` point of all neighboring pairs. Reading order is never broken, and a quantile rather than a fixed cosine means the threshold travels between embedding models;
4. drops units still under `min_tokens` and writes them out for review.

`min_tokens` is enough text for the model to read; `max_tokens` is the point past which a unit starts to hold two subjects. A sensitivity check rebuilds the units at 0.75 and 1.25 times both settings, refits at the same K and spline, and matches each topic to its closest refit topic by word-distribution cosine. A topic that exists at only one way of cutting the text gets a low cosine and deserves caution.

### Choosing K and judging the fit

Candidate K values are fit on most of the text and scored on the rest: held-out likelihood, residual dispersion, semantic coherence, and exclusivity. Take the smallest K where the first two have flattened, then break ties on the last two. Each fit reports **Entropy R²** (how sharply paragraphs sort into topics) and **AvePP** per topic (the average share among its own paragraphs; under about 0.7, the topic mixes subjects).

### Trends with honest intervals

`stm::estimateEffect` fits a linear model that can predict negative shares for rare topics. Instead, each topic's share is regressed on the year spline with a **fractional logit** (quasibinomial GLM; Papke and Wooldridge 1996), so every estimate stays between 0 and 1. The model is refit on 25 draws of the topic shares from the fitted STM and combined on the logit scale, with standard errors **clustered by document**. The interval therefore carries the topic model's own uncertainty as well as the dependence between paragraphs of one document.

### Guarding against stale results

`manifest.csv` records the md5 of every input a cached result was built from. If an input changes, the next render stops and names the file to delete, so a stale fit or codebook is never silently reloaded.

## AI labeling

STM returns topics as word lists. A larger language model drafts a name for each one, under tight limits:

- **One call per topic**, all in parallel, at temperature 0. Each call sees only that topic's 20 most distinctive (FREX) and 20 most probable words and its 5 most typical paragraphs.
- The prompt has a fixed shape (role, task, rules, output) and forbids inferring who is speaking, inventing names, dates or statistics, or smoothing over mixed evidence.
- It returns a **label** (at most 4 words), a **one-sentence description**, and a **proposition**: a single one-sided claim a paragraph on this topic could agree or disagree with. The proposition is the bridge to stance detection.
- The codebook is **drafted once**. If `topic_codebook.csv` exists it is read, never redrafted, so a person's edits survive. Duplicate labels are flagged.

The labels are names, not findings. The words and paragraphs are the evidence, and a person checks every label against them.

## Stance detection

`stance/` measures where text stands on one claim, in any corpus: a topic's paragraphs, or a CSV a user uploads to the stance app.

### Coding

Every passage is coded; nothing is sampled. Each passage goes alone to a local model at temperature 0, without its date or document, and is labeled with one label from the chosen scheme, or **irrelevant** (does not address the claim). The default scheme is **favor, neutral, oppose**; **agree, neutral, disagree** and **aligned, neutral, misaligned** are options in the app and in `stance.qmd` (`scheme`). The prompt is built from the scheme, so each scheme has its own definitions and rules. Only favor/oppose-style stance has evidence behind it (Li and Conrad 2024); run the hand-coded check before relying on the other two, and delete saved labels when you change scheme. Identical passages are sent once and the label copied to each copy; each copy still counts in the estimates, so a form letter sent by 500 people counts 500 times. Only passages of 5 to 250 words are coded, to guard against the wrong unit of text.

### Estimating

A share of all passages confounds attention with agreement, so the estimate is split in two:

$$P(\text{favor}) = P(\text{addresses}) \times P(\text{favor} \mid \text{addresses})$$

- **Salience** is the share of all passages that address the claim: is it live?
- **The labels** (favor, neutral, oppose in the default scheme) are shares of the passages that do address it: which way?

Each is a logistic regression on a natural spline in time, with 95 percent intervals clustered by document. **A period needs at least 30 passages to enter a trend, and a trend needs at least 4 such periods**; otherwise the estimate is static. Time may be a year, `YYYY-MM`, or a date.

### Checking the labels

The intervals treat the labels as correct. To measure how often they are not, code 400 passages by hand without seeing the model's label; the app returns agreement and Cohen's kappa (bootstrapped over documents) and the confusion matrix. Every file from a run carries the same run id, so the check can be done days later in a new session.

## What the numbers do not include

- **Topic assignment is an estimate.** Each paragraph goes to its most likely topic; AvePP says how cleanly.
- **Labels and stance codes come from a model.** Label error is in no interval unless the hand-coded check is run. Re-run stance with a paraphrase of the claim to see whether the result turns on its wording.
- **Every share is a share of passages**, so a long document counts more than a short one. These are not shares of writers.
- **Nothing is weighted.** The methods describe the corpus in front of them, not a wider population.
- **Composition changes.** Who writes changes over time, so a trend mixes change in what is said with change in who said it.
- **Trends are smoothed**, least reliably at the first and last periods and where few passages exist.
- **Dropped text is not neutral.** Units too short to place are left out; if that concentrates in some years, those years rest on longer, better-formed documents. Each render reports the share dropped by year.

## Models and keys

Each script's `steps` table holds the **names** of `.Renviron` variables, never keys:

```
COMPASS_EMBED_URL / COMPASS_EMBED_KEY   embeddings (preprocess)
COMPASS_LARGE_URL / COMPASS_LARGE_KEY   topic labels
```

At home, set `use_openrouter = TRUE` in each topics script; models then come from `topics/llm_openrouter.R` and the key from `OPENROUTER_API_KEY`. At work set it to `FALSE`.

Stance needs no key at work. Set `stance.url` and `stance.model` as strings in `stance/app.R` (and `url`, `model` in `stance.qmd`) and leave the key `NULL`. At home, set them to `NULL` so they come from `.Renviron` in the repo root:

```
OPENROUTER_API_KEY=sk-or-v1-...
STANCE_URL=https://openrouter.ai/api/v1
STANCE_MODEL=google/gemma-4-31b-it
STANCE_KEY=${OPENROUTER_API_KEY}
```

For a local Ollama model, use `STANCE_URL=http://localhost:11434/v1`, the tag `ollama list` shows as `STANCE_MODEL`, and leave `STANCE_KEY` empty.

On Posit Connect, plots use Cairo (`options(bitmapType = "cairo")`) since the server has no X11. For the stance app, set **Max connections per process** to 1: a run holds its R process while it codes.

## Packages

Topics scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, withr, httr2, cli, ellmer (0.4 or later), knitr, glue, arrow.
Stance: shiny, bslib, ggplot2, dplyr, purrr, readr, tibble, withr, splines, httr2 (1.1.1 or later).

## Troubleshooting

| Message | Meaning |
|---|---|
| `X changed since Y was built. Delete Y` | an upstream file changed; delete Y and re-render |
| `N blocks are not embedded. Re-run the chunk` | some embedding requests failed; re-render, embedded blocks are not re-sent |
| `embeddings.parquet was built with 'M'` | the embedding model changed; delete the file to re-embed |
| `stm_fit.rds has K = a but tx$K = b` | delete `stm_fit.rds` |
| `sensitivity.parquet was built at another K` | delete `sensitivity.parquet` |
| `Set X and Y in .Renviron` | the setting is empty; set it, then restart R |
| `The model could not be reached or did not answer` | check `stance.url` and `stance.model`, and that the server can reach the endpoint |
| `N passages got no label; re-render to retry them` | the successes are saved; re-render sends only the rest |
| stance: `X: no trend, N period(s) with at least 30 passages` | not enough dense periods; read the static estimate |
| check: `The two files come from different runs` | download the labeled file and the sheet from the same run |
| request fails with HTTP 401 at home | `STANCE_KEY` is empty |
