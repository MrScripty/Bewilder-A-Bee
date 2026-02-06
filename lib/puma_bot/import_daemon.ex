defmodule PumaBot.ImportDaemon do
  @moduledoc """
  Background daemon that polls WhatsApp for new messages.

  This GenServer polls the WhatsApp bridge at regular intervals,
  importing any new messages into the database.

  Note: Claude Code import is manual-only via `./launcher.sh import`
  as it's a bulk operation that doesn't need continuous polling.

  ## Usage

  The daemon starts automatically with the application when using `./launcher.sh run`.
  It can be disabled by setting `PUMA_IMPORT_DAEMON=false` environment variable.

  ## Manual control

      # Check status
      PumaBot.ImportDaemon.status()

      # Trigger immediate import
      PumaBot.ImportDaemon.import_now()

      # Pause/resume
      PumaBot.ImportDaemon.pause()
      PumaBot.ImportDaemon.resume()
  """

  use GenServer
  require Logger

  @poll_interval 30_000  # 30 seconds

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current daemon status"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Trigger an immediate import cycle"
  def import_now do
    GenServer.cast(__MODULE__, :import_now)
  end

  @doc "Pause automatic imports"
  def pause do
    GenServer.cast(__MODULE__, :pause)
  end

  @doc "Resume automatic imports"
  def resume do
    GenServer.cast(__MODULE__, :resume)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # Check if daemon should be enabled
    enabled = System.get_env("PUMA_IMPORT_DAEMON", "true") != "false"

    state = %{
      enabled: enabled,
      paused: false,
      last_run: nil,
      last_results: nil,
      import_count: 0,
      timer_ref: nil
    }

    if enabled do
      Logger.info("[ImportDaemon] Starting (polling every #{div(@poll_interval, 1000)}s)")
      # Run first import after a short delay to let other services start
      timer_ref = schedule_import(5_000)
      {:ok, %{state | timer_ref: timer_ref}}
    else
      Logger.info("[ImportDaemon] Disabled via PUMA_IMPORT_DAEMON=false")
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      paused: state.paused,
      last_run: state.last_run,
      last_results: state.last_results,
      import_count: state.import_count,
      next_run_in: if(state.timer_ref, do: "~#{div(@poll_interval, 1000)}s", else: nil)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_cast(:import_now, state) do
    if state.enabled and not state.paused do
      state = run_import(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("[ImportDaemon] Paused")
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    {:noreply, %{state | paused: true, timer_ref: nil}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("[ImportDaemon] Resumed")
    timer_ref = schedule_import()
    {:noreply, %{state | paused: false, timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:import, state) do
    state = if state.enabled and not state.paused do
      run_import(state)
    else
      state
    end

    # Schedule next import
    timer_ref = if state.enabled and not state.paused do
      schedule_import()
    else
      nil
    end

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # --- Private Functions ---

  defp schedule_import(delay \\ @poll_interval) do
    Process.send_after(self(), :import, delay)
  end

  defp run_import(state) do
    Logger.debug("[ImportDaemon] Running import cycle ##{state.import_count + 1}")

    # Only poll WhatsApp - Claude import is manual via ./launcher.sh import
    whatsapp_result = run_whatsapp_import()

    # Log summary if new messages
    case whatsapp_result do
      {:ok, %{messages: m}} when m > 0 ->
        Logger.info("[ImportDaemon] +#{m} WhatsApp")
      _ ->
        :ok
    end

    %{state |
      last_run: DateTime.utc_now(),
      last_results: %{whatsapp: whatsapp_result},
      import_count: state.import_count + 1
    }
  end

  defp run_whatsapp_import do
    try do
      # First check if bridge is reachable
      case PumaBot.WhatsApp.Client.status() do
        {:ok, status} ->
          if status["connected"] || status[:connected] do
            case PumaBot.Importers.WhatsAppImporter.import_all(quiet: true) do
              {:ok, stats} -> {:ok, stats}
              {:error, reason} -> {:error, reason}
            end
          else
            # Not connected yet, not an error
            {:ok, %{messages: 0, sessions: 0, errors: 0}}
          end

        {:error, {:request_failed, :econnrefused}} ->
          # Bridge not running - silently skip (don't log, this is expected)
          {:ok, %{messages: 0, sessions: 0, errors: 0, skipped: :bridge_not_running}}

        {:error, {:request_failed, _}} ->
          # Other connection issues - silently skip
          {:ok, %{messages: 0, sessions: 0, errors: 0, skipped: :bridge_error}}

        {:error, reason} ->
          Logger.warning("[ImportDaemon] WhatsApp bridge error: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

end
