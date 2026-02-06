defmodule PumaBot.Importers.Importer do
  @moduledoc """
  Unified import coordinator for all data sources.

  Runs all registered importers and reports combined statistics.
  Each importer handles its own deduplication via database constraints.

  ## Usage

      # Import all sources
      Importer.run_all()

      # Show import status
      Importer.status()

      # Import specific source
      Importer.run(:claude_code)
  """

  alias PumaBot.Importers.ClaudeImporter
  alias PumaBot.Importers.WhatsAppImporter
  alias PumaBot.Data.DataSource
  alias PumaBot.Repo

  require Logger

  # Registry of available importers
  # Format: {source_type, module, display_name}
  @importers [
    {:claude_code, ClaudeImporter, "Claude Code conversations"},
    {:whatsapp, WhatsAppImporter, "WhatsApp messages"}
    # Future importers:
    # {:git, GitImporter, "Git commits"},
  ]

  @doc """
  Returns the list of registered importers.
  """
  def importers, do: @importers

  @doc """
  Returns the list of available source types.
  """
  def source_types do
    Enum.map(@importers, fn {type, _, _} -> type end)
  end

  @doc """
  Runs all registered importers.

  Returns a map of results per source type.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  """
  @spec run_all(keyword()) :: map()
  def run_all(opts \\ []) do
    IO.puts("")
    IO.puts("🐆 PumaBot Data Import")
    IO.puts("======================")

    results =
      Enum.reduce(@importers, %{}, fn {source_type, module, name}, acc ->
        IO.puts("")
        IO.puts("📥 #{name}...")

        case run_importer(module, opts) do
          {:ok, stats} ->
            IO.puts("   ✓ #{stats.sessions} sessions, #{stats.messages} messages imported")

            if stats.errors > 0 do
              IO.puts("   ⚠ #{stats.errors} errors")
            end

            Map.put(acc, source_type, {:ok, stats})

          {:error, reason} ->
            IO.puts("   ✗ Failed: #{inspect(reason)}")
            Map.put(acc, source_type, {:error, reason})
        end
      end)

    print_summary()
    results
  end

  @doc """
  Runs a specific importer by source type.

  ## Examples

      Importer.run(:claude_code)
      Importer.run(:whatsapp, with_embeddings: true)
  """
  @spec run(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(source_type, opts \\ []) do
    case find_importer(source_type) do
      {:ok, {_, module, name}} ->
        IO.puts("")
        IO.puts("📥 Importing #{name}...")
        result = run_importer(module, opts)
        print_summary()
        result

      :error ->
        {:error, {:unknown_source, source_type}}
    end
  end

  @doc """
  Shows the current import status for all sources.
  """
  @spec status() :: :ok
  def status do
    IO.puts("")
    IO.puts("🐆 PumaBot Import Status")
    IO.puts("========================")
    IO.puts("")

    Enum.each(@importers, fn {source_type, module, name} ->
      count = get_source_count(source_type, module)
      IO.puts("#{name}: #{count} records")
    end)

    IO.puts("")
    IO.puts("Total data sources: #{total_data_sources()}")
    IO.puts("")
    :ok
  end

  # --- Private Functions ---

  defp run_importer(module, opts) do
    module.import_all(opts)
  end

  defp find_importer(source_type) do
    case Enum.find(@importers, fn {type, _, _} -> type == source_type end) do
      nil -> :error
      importer -> {:ok, importer}
    end
  end

  defp get_source_count(:claude_code, module) do
    module.count_conversations()
  end

  defp get_source_count(:whatsapp, module) do
    module.count_messages()
  end

  defp get_source_count(_source_type, _module) do
    0
  end

  defp total_data_sources do
    Repo.aggregate(DataSource, :count)
  end

  defp print_summary do
    IO.puts("")
    IO.puts("─────────────────────────")

    Enum.each(@importers, fn {source_type, module, name} ->
      count = get_source_count(source_type, module)
      IO.puts("#{name}: #{count}")
    end)

    import Ecto.Query

    ds_counts =
      from(ds in DataSource, group_by: ds.source_type, select: {ds.source_type, count(ds.id)})
      |> Repo.all()
      |> Enum.into(%{})

    IO.puts("")
    IO.puts("Data sources for RAG:")

    if map_size(ds_counts) == 0 do
      IO.puts("  (none yet)")
    else
      Enum.each(ds_counts, fn {type, count} ->
        IO.puts("  #{type}: #{count}")
      end)
    end

    IO.puts("")
  end
end
