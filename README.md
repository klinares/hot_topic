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
- The prompt is saved beside the codebook as `codebook_prompt.txt`, and the dashboard prints it on **Start here** with why it is written that way and what it has been run on.

The labels are names, not findings. The words and paragraphs are the evidence, and a person checks every label against them.

## Stance detection

`stance/` measures where text stands on one claim, in any corpus: a topic's paragraphs, or a CSV a user uploads to the stance app.

### Coding

Every chat model may be sent only 300 requests per 4 hours, each model on its own count; the embedding model has no limit. So no model reads the whole file. The labeling model (Sonnet) reads a **probability sample**, weighted up to the whole file, and requests are spent a few at a time rather than all at once.

1. **Screen.** The embedding model places the claim and every passage. Passages are sorted by closeness to the claim into four groups (5, 15, 30, and 50 percent of the file). Nothing is dropped or assumed irrelevant: the screen only decides where to look harder. A file small enough to label whole is not screened.
2. **Sample and label.** Sonnet reads a random sample from every group, the same number from each, so the closest 5 percent is read about ten times as closely as the farthest half. Each passage gets one label from the chosen scheme, or **irrelevant** (does not address the claim). Identical passages are sent once. Only passages of 5 to 250 words are sampled.
3. **Several passages to a request** (`stance.per_request`, 10). The limit counts requests, not passages, so 30 requests label about 200 passages (after the check below) and 300 would label about 2,900. Passages go numbered, in shuffled order, with the instruction to judge each on its own. Whether a passage's neighbors sway its label is measured on every round: `stance.solo_n` (10) passages are also sent alone, and the results show how often the two readings agree. If they disagree, set `stance.per_request` to 1.
4. **Helpers** (Opus, Gemma, Llama; `helpers =` in `stance_models()`). They read the same passages as Sonnet and further ones in the same random order, dealt out among them at random, each on its own 300 requests. Their labels are not trusted: on the passages both read, Sonnet's own frequencies translate each helper label into chances of Sonnet's labels, those chances are totaled over everything the helpers read, and Sonnet's sample measures and removes the remaining error (double sampling with a fallible classifier). The estimates stay estimates of what Sonnet would say about the whole file, however the helpers lean. Helpers are used once 100 passages have been read by both. The results also report each helper's agreement with Sonnet.
5. **Weigh.** Each label stands for the unread passages of its group (weight = passages in the group / read in the group). The 95 percent intervals carry the sampling and the clustering of passages in documents.
6. **Add.** Every passage has a fixed place in one random order and a group's sample is its first passages in that order, so two rounds are the same sample as one round twice the size. In the app, press **Label passages** again, or upload the file with labels on another day (after the 4 hours, say); in `stance.qmd`, raise `n_label` and render again. Only the new passages are sent.

Why not label the passages closest to the claim and call the rest irrelevant: that assumes the answer. Positions taken by implication sit farther from the claim's wording, so a cutoff understates salience and tilts direction toward the side that states its view outright. In a simulation with a known answer, a top-295 cutoff reported 3 percent salience where the truth was 12.

What simulation showed, on files with a known answer. The sample is unbiased and its intervals hold the truth about 95 percent of the time (down to about 90 for a rare label). Helpers that were wrong on one passage in five and leaned one way did not bias the estimates. Their gain is modest: intervals 10 to 30 percent narrower when they agree with Sonnet on nine passages in ten and read the whole file, little when they read only three times what Sonnet read. The large gain is several passages to a request: ten times the labels makes intervals about a third as wide. An approach that was tried and dropped: predicting labels from the embeddings gave no narrowing.

The default scheme is **favor, neutral, oppose**; **agree, neutral, disagree** and **aligned, neutral, misaligned** are options in the app and in `stance.qmd` (`scheme`). The prompt is built from the scheme. Only favor/oppose-style stance has evidence behind it (Li and Conrad 2024); run the hand-coded check before relying on the other two. A changed claim, scheme, or description starts a new sample. The app's **Start here** page prints the prompt for each scheme and why each part is there.

### Estimating

A share of all passages confounds attention with agreement, so the estimate is split in two:

$$P(\text{favor}) = P(\text{addresses}) \times P(\text{favor} \mid \text{addresses})$$

- **Salience** is the share of all passages that address the claim: is it live?
- **The labels** (favor, neutral, oppose in the default scheme) are shares of the passages that do address it: which way?

Each is a weighted share (the labels as a ratio of two weighted totals), sharpened by the helpers when there are enough passages read by both. Trends use Sonnet's sample alone. With a time column, each is also a weighted logistic regression on a natural spline in time, with 95 percent intervals clustered by document. **A trend needs at least 60 labeled passages over at least 4 periods on its own basis**; otherwise the estimate is static. Time may be a year, `YYYY-MM`, or a date. The results also list the groups with the share of each group's labeled passages that address the claim, which shows what a similarity cutoff would have missed.

### Checking the labels

The intervals treat the labels as correct. To measure how often they are not, code the sheet of labeled passages by hand (up to 400), without seeing the model's label; the app returns agreement and Cohen's kappa (weighted like the estimates, bootstrapped over documents) and the confusion matrix. Every file from a run carries the same run id, so the check can be done days later in a new session.

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

**The stance app** uses one OpenAI-compatible endpoint and one key for every model: an embedding model, the labeling model (Sonnet), and the helpers (Opus, Gemma, Llama). The base URL and the model IDs are set in `stance/app.R` (`stance.base_url`, `stance.models`); paste them there, and the app will not start while a placeholder is left. `chat_model()` takes a model's ID and the request settings it needs: Claude models take no temperature and need thinking switched off, open models take temperature 0. The user chooses how many requests to send each model per round (`stance.batch`, 30, is the default offered), and the page shows how many the session has sent each model. The limit counts across sessions, so a round can still be refused; labeling stops at the first refusal, keeps what it has as a valid sample, and reports the rest. A helper that fails costs a note, not the labels. The user pastes their own API key (**Use this key**; **Forget it** drops it) and presses **Check connection**: one short request to each model. A run stays locked until every model answers, and a new key locks it again. The error shown names the model and the problem (bad key, unknown model, unreachable host, rate limit, an empty reply), never the key. There is no server key: the app reads no environment variable, sets none, and writes the key into no file. The banner (UNCLASSIFIED) and the logo (`logo/office_logo.png`) are set in `app.R` itself.

**`stance.qmd`** takes the base URL and the models in its config (`url`, `embed_model`, `st$model`, `st$helpers`) and the key from `STANCE_KEY` in `.Renviron` in the repo root, never from the script:

```
STANCE_KEY=...
```

On Posit Connect, plots use Cairo (`options(bitmapType = "cairo")`) since the server has no X11. For the stance app, set **Max connections per process** to 1: a run holds its R process while it codes.

## Packages

Topics scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, withr, httr2, cli, ellmer (0.4 or later), knitr, glue, arrow.
Stance: shiny, bslib, ggplot2, dplyr, purrr, readr, tibble, withr, splines, httr2 (1.1.1 or later).
Stance tests: testthat and webfakes. Run `testthat::test_dir("stance/tests/testthat")`; the tests use local mock servers, so no network and no real key.

## Troubleshooting

| Message | Meaning |
|---|---|
| `X changed since Y was built. Delete Y` | an upstream file changed; delete Y and re-render |
| `N blocks are not embedded. Re-run the chunk` | some embedding requests failed; re-render, embedded blocks are not re-sent |
| `embeddings.parquet was built with 'M'` | the embedding model changed; delete the file to re-embed |
| `stm_fit.rds has K = a but tx$K = b` | delete `stm_fit.rds` |
| `sensitivity.parquet was built at another K` | delete `sensitivity.parquet` |
| `Set X and Y in .Renviron` | the setting is empty; set it, then restart R |
| `No answer from <model> at <url>: ...` | the provider's own message follows: a 401 is the key, a 404 usually the model name or the URL; fix it and check the connection again |
| `Paste the base URL and the model IDs into app.R` | `stance.base_url` or a model ID in `stance.models` is still a placeholder |
| stance app: `N sampled passage(s) have no label yet` | each reason is listed; the labeled file's `stance_note` column gives it per row. Refused requests are retried by the next batch |
| `N passages got no label and are left out` | the report reads saved labels; delete the named labels file to send the corpus again |
| stance: `X: no trend, N labeled passage(s) in M period(s)` | a trend needs 60 labeled passages over 4 periods on that basis; label more, or read the static estimate |
| check: `The two files come from different runs` | download the labeled file and the sheet from the same run |
| request fails with HTTP 401 at home | `STANCE_KEY` is empty |
