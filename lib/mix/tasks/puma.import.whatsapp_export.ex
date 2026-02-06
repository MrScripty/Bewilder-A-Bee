defmodule Mix.Tasks.Puma.Import.WhatsappExport do
  @moduledoc """
  Imports WhatsApp messages from exported .txt files.

  Use WhatsApp's built-in export feature (Chat → ⋮ → More → Export Chat)
  to create .txt files, then import them with this command.

  ## Usage

      # Import a single file
      mix puma.import.whatsapp_export --file "/path/to/WhatsApp Chat with John.txt"

      # Import all exports from a directory
      mix puma.import.whatsapp_export --dir "/path/to/exports/"

      # Specify your name for is_from_me detection
      mix puma.import.whatsapp_export --file chat.txt --my-name "Jeremy"

      # Generate embeddings during import
      mix puma.import.whatsapp_export --dir ./exports --with-embeddings

      # List files in a directory without importing
      mix puma.import.whatsapp_export --list --dir ./exports

  ## Options

    * `--file` - Import a single export file
    * `--dir` - Import all .txt files from a directory
    * `--my-name` - Your name as it appears in exports (for is_from_me detection)
    * `--with-embeddings` - Generate embeddings during import
    * `--include-others` - Also store other people's messages in data_sources
    * `--list` - List files without importing
  """

  use Mix.Task

  alias PumaBot.Importers.WhatsAppExportImporter

  @shortdoc "Import WhatsApp chat exports (.txt files)"

  @switches [
    file: :string,
    dir: :string,
    my_name: :string,
    with_embeddings: :boolean,
    include_others: :boolean,
    list: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} = OptionParser.parse(args, switches: @switches)

    Mix.Task.run("app.start")

    cond do
      opts[:list] && opts[:dir] ->
        list_files(opts[:dir])

      opts[:file] ->
        import_file(opts[:file], opts)

      opts[:dir] ->
        import_directory(opts[:dir], opts)

      true ->
        Mix.shell().error("Please specify --file or --dir")
        Mix.shell().info("")
        Mix.shell().info("Examples:")
        Mix.shell().info("  mix puma.import.whatsapp_export --file \"WhatsApp Chat.txt\"")
        Mix.shell().info("  mix puma.import.whatsapp_export --dir ./exports --my-name \"Jeremy\"")
    end
  end

  defp list_files(dir) do
    Mix.shell().info("")
    Mix.shell().info("WhatsApp Export Files")
    Mix.shell().info("=====================")
    Mix.shell().info("")

    files = WhatsAppExportImporter.list_exports(dir)

    if Enum.empty?(files) do
      Mix.shell().info("No .txt files found in #{dir}")
    else
      Mix.shell().info("Found #{length(files)} files:\n")
      Enum.each(files, fn file ->
        Mix.shell().info("  #{Path.basename(file)}")
      end)
    end

    Mix.shell().info("")
  end

  defp import_file(file_path, opts) do
    import_opts = build_import_opts(opts)

    Mix.shell().info("")
    Mix.shell().info("Importing: #{file_path}")
    Mix.shell().info("")

    case WhatsAppExportImporter.import_file(file_path, import_opts) do
      {:ok, stats} ->
        Mix.shell().info("✓ Imported #{stats.messages} messages")
        Mix.shell().info("  Skipped: #{stats.skipped}")
        Mix.shell().info("  Errors: #{stats.errors}")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end

    print_summary()
  end

  defp import_directory(dir_path, opts) do
    import_opts = build_import_opts(opts)

    Mix.shell().info("")
    Mix.shell().info("Importing WhatsApp exports from: #{dir_path}")
    Mix.shell().info("")

    case WhatsAppExportImporter.import_directory(dir_path, import_opts) do
      {:ok, stats} ->
        Mix.shell().info("")
        Mix.shell().info("Import complete!")
        Mix.shell().info("  Files: #{stats.files}")
        Mix.shell().info("  Messages: #{stats.messages}")
        Mix.shell().info("  Skipped: #{stats.skipped}")
        Mix.shell().info("  Errors: #{stats.errors}")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end

    print_summary()
  end

  defp build_import_opts(opts) do
    [
      with_embeddings: opts[:with_embeddings] || false,
      user_only: not (opts[:include_others] || false),
      my_name: opts[:my_name]
    ]
  end

  defp print_summary do
    alias PumaBot.Importers.WhatsAppImporter

    Mix.shell().info("")
    Mix.shell().info("Database Summary")
    Mix.shell().info("----------------")
    Mix.shell().info("  WhatsApp messages: #{WhatsAppImporter.count_messages()}")
    Mix.shell().info("  WhatsApp data sources: #{WhatsAppImporter.count_data_sources()}")
    Mix.shell().info("")
  end
end
