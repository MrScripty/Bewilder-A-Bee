defmodule Mix.Tasks.Puma.Import do
  @moduledoc """
  Imports all data sources into PumaBot.

  This is the main entry point for data ingestion. It runs all registered
  importers (Claude Code, WhatsApp, etc.) and handles deduplication
  automatically via database constraints.

  ## Usage

      # Import all sources
      mix puma.import

      # Show current import status
      mix puma.import --status

      # Import specific source only
      mix puma.import --source claude_code

      # Generate embeddings during import (requires Ollama)
      mix puma.import --with-embeddings

      # Backfill chat names for WhatsApp messages (requires bridge running)
      mix puma.import --backfill-chat-names

  ## Available Sources

      claude_code   - Claude Code conversations from ~/.claude/projects/
      whatsapp      - WhatsApp messages (coming soon)
      git           - Git commits (coming soon)
  """

  use Mix.Task

  alias PumaBot.Importers.Importer
  alias PumaBot.Importers.WhatsAppImporter

  @shortdoc "Import all data sources"

  @switches [
    status: :boolean,
    source: :string,
    with_embeddings: :boolean,
    backfill_chat_names: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} = OptionParser.parse(args, switches: @switches)

    # Start the application
    Mix.Task.run("app.start")

    cond do
      opts[:status] ->
        Importer.status()

      opts[:backfill_chat_names] ->
        backfill_chat_names()

      opts[:source] ->
        source = String.to_existing_atom(opts[:source])
        import_opts = build_import_opts(opts)
        Importer.run(source, import_opts)

      true ->
        import_opts = build_import_opts(opts)
        Importer.run_all(import_opts)
    end
  end

  defp build_import_opts(opts) do
    [
      with_embeddings: opts[:with_embeddings] || false
    ]
  end

  defp backfill_chat_names do
    IO.puts("\n📥 Backfilling WhatsApp chat names...")

    case WhatsAppImporter.backfill_chat_names() do
      {:ok, stats} ->
        IO.puts("✅ Updated #{stats.updated} messages across #{stats.chats} chats")

      {:error, {:request_failed, :econnrefused}} ->
        IO.puts("❌ WhatsApp bridge is not running. Start it with: ./launcher.sh whatsapp")

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
    end
  end
end
