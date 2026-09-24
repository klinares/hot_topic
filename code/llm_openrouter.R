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

# Embeddings through OpenRouter's OpenAI-compatible endpoint.
embed_home <- function(txt, model) {
  ragnar::embed_openai(txt, model = sub("^openrouter/", "", model),
                       base_url = "https://openrouter.ai/api/v1",
                       api_key = Sys.getenv("OPENROUTER_API_KEY"),
                       user = NULL,  # ragnar sends a "user" field by default;
                                     # Mistral's API rejects it (HTTP 422)
                       batch_size = 10000L)
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
