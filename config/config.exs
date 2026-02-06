# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :puma_bot,
  ecto_repos: [PumaBot.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Ollama configuration
  ollama_host: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  ollama_chat_model: System.get_env("OLLAMA_CHAT_MODEL", "qwen3:latest"),
  ollama_embed_model: System.get_env("OLLAMA_EMBED_MODEL", "nomic-embed-text")

# Configure the endpoint
config :puma_bot, PumaBotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PumaBotWeb.ErrorHTML, json: PumaBotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PumaBot.PubSub,
  live_view: [signing_salt: "SKDjl2Ip"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
