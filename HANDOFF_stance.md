# Handoff: stance app, user-supplied key and model, tests, simplification

Paste this whole file into Claude Code, started in `D:\repos\hot_topic`. Read
it to the end before touching code.

## Who I am and how I work

I'm Kevin, a survey methodologist. I write R in the tidyverse style. Rules
that apply to every line you write:

- **Never use `for` loops in R.** Use `purrr::map()` and its relatives.
- Native pipe `|>`, `dplyr::` namespacing in package-style files, minimal and readable code with short comments that explain *why*.
- **API keys never go in code, logs, files, downloads or `Sys.setenv()`.**
- No em-dashes in prose (UI text, README, comments).
- Don't hand me untested code as if it works. Say what you ran and what you didn't.
- Ask before deleting files or making large structural changes. Prefer deleting code to adding it.

## The project

`hot_topic` has two independent tools. **Only `stance/` is in scope here.**
Don't touch `topics/`.

`stance/` is a Shiny app (deployed on Posit Connect) plus a Quarto report
(`stance.qmd`). A user uploads a CSV of short passages, writes one claim, and
picks a label scheme (favor, agree or aligned). Every passage is sent alone to
an OpenAI-compatible `/chat/completions` endpoint at temperature 0, and the
one-word reply becomes the label. The app reports salience (share of
passages addressing the claim) and direction (shares among relevant
passages), static or as trends with clustered 95% intervals. It also writes a
400-passage hand-coding sheet, and the Check the labels tab computes
agreement (Cohen's kappa) from the labeled file and the hand-coded sheet,
matched by run id. The app keeps no state between sessions.

```
stance/
  app.R                 settings block, banner and logo, page layout
  R/stance_core.R       prompt, requests (httr2), parsing, estimates, plots, agreement
  R/ui_stance.R         Detect stance and Check the labels (module mod_stance_*)
  R/ui_stance_help.R    Start here page
  R/ui_stance_prompt.R  Start here card printing the prompt per scheme
  R/classification.R    OBSOLETE: banner and logo now live in app.R; delete it
  stance.qmd            the method report (renders stance.pdf); uses st$url/st$model/st$key
  stance_source.R       helpers for stance.qmd only
  inputs/ outputs/      data for stance.qmd (inputs/ is gitignored)
```

### How the connection works today (read the code to confirm)

- `app.R` sets `options(stance.model = "gemma4:31b", stance.reasoning_effort = "none", stance.workers, stance.sec_per_passage, stance.call_limit = 300)`.
- On Detect stance, step 1 "Connect to the model" has an Endpoint URL text box, an API key `passwordInput`, and a **Check connection** button.
- `stance_check(ep)` in `stance_core.R` sends one short request with the real model and settings. It returns `list(ok, secs, message)`, and the message carries the provider's error body (401 bad key, 404 unknown model, unreachable host, empty reply meaning the model is thinking).
- The checked endpoint is held in `conn <- reactiveVal(NULL)` inside the module. Editing the URL or key clears it. A run refuses to start until `conn()` is set.
- `stance_endpoint(url, model, key, reasoning_effort)` builds the endpoint list. A `NULL` url, model or key falls back to `STANCE_URL`, `STANCE_MODEL` and `STANCE_KEY` (used by `stance.qmd`).
- The model name is written into every labeled row (`stance_model`) and into the estimates. The key is never written anywhere; a test confirmed it's absent from all downloads.

## The task

### 1. Change who supplies what

| Item | Now | Wanted |
|---|---|---|
| base URL | typed by the user | **hard-coded in `app.R`** (`stance.base_url`) |
| API key | typed by the user | typed by the user (unchanged) |
| model | hard-coded `stance.model` | **chosen by the user** |

The design follows my DrSvyR app (`ui_chat.R`, `llm.R`):
- Masked key field, with **Use this key** and **Forget it** buttons.
- Clear the input box after the key is accepted.
- A status line: key in use, or none.
- A note that the key lives for this session only, is never saved and isn't in any result.

You don't need DrSvyR's process-wide key registry keyed by `session$token`. It exists there because model calls happen deep outside the modules. In this app every call starts inside `mod_stance_server`, so a `reactiveVal` in the module is already per-session and dies with it. Keep that; it's simpler. If you disagree, explain why before changing it.

**Model selection.** Default plan:
- After the key is accepted, call `GET {base_url}/models` with the key.
- If it returns a list, offer it in a `selectizeInput` that also accepts typed text (`options = list(create = TRUE)`), because some endpoints don't list every model, or list none.
- If `/models` fails, fall back to a plain text box and say so.
- Pre-select `getOption("stance.default_model")` if it's in the list (set it to the gemma4 name in `app.R`).

**The check.** **Check connection** then runs `stance_check()` with base_url, key and model. A run stays locked until it passes, and changing the key or the model clears it.

**Reasoning effort.** `reasoning_effort` is model-specific; some endpoints reject the parameter. If the check fails with a 400 whose body mentions `reasoning_effort`, retry once without it and remember that for the session. Keep this small: about 5 lines.

**A non-default model.** If the chosen model isn't the default, show a short warning under the check result: the prompt was written and tested with gemma4, labels from another model haven't been checked against hand coding, and the user should do the 400-passage check before reporting.

**Keep:**
- the model name recorded in every output row and in the run id (check how `stance_run_id()` is built, so a re-run with another model is told apart);
- the time estimate and the `stance.call_limit` warning;
- the Start here page and prompt card, but update their text: "Model: chosen on Detect stance, at <base_url>". The prompt card's request-settings line shouldn't claim `reasoning_effort` when it was dropped. It can say "when the endpoint accepts it".

**`stance.qmd` stays script-driven** (`st$url`, `st$model`, `st$key = NULL` reading `STANCE_KEY` from `.Renviron`). Make sure the changed `stance_endpoint()` / `stance_check()` signatures still work for it.

### 2. Test so we find bugs

The old tests (`t1_core.R` to `t5_qmd.R`, and others from earlier sessions) are outside the repo, predate the label schemes, and no longer match the code. **Replace them** with a `testthat` suite in `stance/tests/testthat/`, run with `testthat::test_dir("stance/tests/testthat")`. Use a local mock server (`webfakes`) for the endpoint: no real network, no real key.

Minimum coverage:

- **Core functions:**
  - `stance_screen()` word bounds (5 to 250) and reasons;
  - `stance_prepare()` with and without time and document columns;
  - `stance_parse()` for each scheme, including replies with extra words, punctuation, upper case, an empty reply, and a reply naming a label from another scheme;
  - duplicate passages sent once (count requests on the mock) and labels copied back in the right order;
  - `stance_static()` and the trend rule (period ≥ 30 passages, ≥ 4 such periods, otherwise static);
  - salience = 1 − irrelevant share; the direction shares among relevant passages sum to 1;
  - intervals inside [0, 1].
- **Endpoint and connection:**
  - good key and model pass;
  - bad key gives 401 with the provider's message shown;
  - unknown model gives 404;
  - unreachable host;
  - empty reply gives the thinking hint;
  - a 400 mentioning `reasoning_effort` is retried without it;
  - `/models` success fills the choices; `/models` failure falls back to free text;
  - the key never appears in any message, label file, estimates file, sheet or prompt file.
- **Rate limits:** a mock that returns 429 after N calls. Confirm what the user sees: unlabeled passages are counted and reported, the app doesn't crash, and no label is invented. Report what actually happens; don't paper over it.
- **Module (`shiny::testServer(mod_stance_server, ...)`):**
  - no run without a passed check;
  - Forget it clears the key and the connection;
  - changing the model clears the connection;
  - a full run on a small CSV gives the expected labels and estimates;
  - downloads contain the chosen model name;
  - the Check the labels tab matches the run's labeled file and its sheet, and refuses a sheet from another run.
- **`app.R` smoke test:** source it, build the UI, and confirm the banner, the logo placeholder and the three tabs render with no error.
- **`stance.qmd`:** at least `knitr::purl()` it and run the code against the mock. Quarto may not be installed; say so if it isn't.

When a test finds a bug, fix the code, not the test, unless the test was wrong. List every bug found in your final summary.

### 3. Simplify

After the tests pass, look for code to delete or merge, then rerun the suite:

- **Delete `stance/R/classification.R`** (nothing calls it). Ask before deleting anything else.
- **Remove dead code:** functions nobody calls, options nobody reads. Grep, for example, for `stance.tested`, `stance.docs`, `stance.url_hint` (made obsolete by the hard-coded URL) and `stance_source.R` helpers that duplicate `stance_core.R`.
- **Collapse repetition:** any helper used once that adds nothing.
- **Keep the comments that explain why;** cut comments that restate the code.
- Report line counts per file before and after.

Don't change the method: the prompt text, the label schemes, the screening bounds, the trend rule, the interval method and the agreement statistics stay as they are, unless a test proves one is wrong. If one is, stop and tell me rather than changing it.

### 4. Docs

Update `README.md` (the stance sections), the Start here text, and the comments at the top of `app.R` so they describe: base URL fixed in `app.R`, key and model from the user, and the check before a run. Keep them short.

## Settings block I expect in `app.R` afterwards

```r
options(
  stance.base_url = "https://YOUR-ENDPOINT/v1",  # the only hard-coded connection detail
  stance.default_model = "gemma4 model name",    # pre-selected; the prompt was tested on it
  stance.reasoning_effort = "none",              # dropped automatically if the endpoint rejects it
  stance.workers = 1,
  stance.sec_per_passage = 0.1,
  stance.call_limit = 300)                       # requests per window, for the warning
```

## Constraints and context

- The endpoint allows about **300 requests per 4 hours**. Don't run anything against a real endpoint without asking me; use the mock.
- R packages already used: shiny, bslib, httr2 (≥ 1.1.1 for `req_perform_parallel(max_active =)`), dplyr, readr, purrr, ggplot2, splines, glue, withr, DT. Test-only additions (`testthat`, `webfakes`) are fine. Ask before adding any runtime package.
- On Posit Connect, "Max connections per process" is 1, so each user gets their own R process. Even so, don't store keys in globals or options.
- Windows paths: the repo is at `D:\repos\hot_topic`.

## When you finish

Give me:
1. What changed, file by file, in a few lines each.
2. The test results: how many tests, all passing or not, and the bugs found and fixed.
3. Line counts before and after.
4. Anything you could not test, and anything you think is still risky.
5. Files you want me to delete or that you deleted.

Before you start, ask me anything this file leaves unclear.
