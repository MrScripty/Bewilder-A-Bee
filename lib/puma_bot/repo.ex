defmodule PumaBot.Repo do
  use Ecto.Repo,
    otp_app: :puma_bot,
    adapter: Ecto.Adapters.Postgres

  # Register pgvector types for Ecto
  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :types, PumaBot.PostgresTypes)}
  end
end
