# llm_openrouter.R -----------------------------------------------------------
# OpenRouter provider. Delete this file and set use_openrouter = FALSE in each
# script's config to route through an OpenAI-compatible endpoint instead; the
# router in llm_source.R then reads base_url_env, api_key_env, and model from
# each script's steps table. Scripts source this file only when their
# use_openrouter flag is TRUE, and nothing else references it.
#
# The key lives in .Renviron, never here: OPENROUTER_API_KEY.

make_chat_home <- function(model, system_prompt) {
  ellmer::chat_openrouter(
    model = sub("^openrouter/", "", model),  # the slug itself contains a "/"
    system_prompt = system_prompt,
    params = ellmer::params(temperature = 0),
    echo = "none")
}

# Embedding endpoint through OpenRouter's OpenAI-compatible route.
embed_endpoint_home <- function(model) {
  list(url = "https://openrouter.ai/api/v1",
       key = Sys.getenv("OPENROUTER_API_KEY"),
       model = sub("^openrouter/", "", unname(model)))
}

# Model per pipeline step. When use_openrouter = TRUE, these replace the model
# column of each script's steps table by step name.
open_router_models <- c(
  embed = "openrouter/mistralai/mistral-embed-2312",
  label = "openrouter/meta-llama/llama-3.3-70b-instruct",
  manager = "openrouter/meta-llama/llama-4-maverick",
  proposition = "openrouter/meta-llama/llama-4-maverick",
  stance_1 = "openrouter/google/gemma-4-31b-it",
  stance_2 = "openrouter/meta-llama/llama-3.1-70b-instruct")
