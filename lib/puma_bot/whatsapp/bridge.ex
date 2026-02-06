defmodule PumaBot.WhatsApp.Bridge do
  @moduledoc """
  Manages the WhatsApp Bridge Node.js process.

  Allows starting/stopping the bridge from Elixir code (including the GUI).
  """

  use GenServer
  require Logger

  @bridge_dir "services/whatsapp-bridge"

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start the WhatsApp bridge process"
  def start_bridge do
    GenServer.call(__MODULE__, :start_bridge, 30_000)
  end

  @doc "Stop the WhatsApp bridge process"
  def stop_bridge do
    GenServer.call(__MODULE__, :stop_bridge)
  end

  @doc "Check if bridge process is running"
  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  @doc "Get bridge status (process + connection)"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{port: nil, os_pid: nil}}
  end

  @impl true
  def handle_call(:start_bridge, _from, %{port: nil} = state) do
    bridge_path = Path.join(Application.app_dir(:puma_bot, "priv"), "../../../#{@bridge_dir}")
    |> Path.expand()

    # Check if directory exists, fall back to relative path
    bridge_path =
      if File.dir?(bridge_path) do
        bridge_path
      else
        Path.join(File.cwd!(), @bridge_dir)
      end

    unless File.dir?(bridge_path) do
      {:reply, {:error, :bridge_not_found}, state}
    else
      Logger.info("[Bridge] Starting WhatsApp bridge from #{bridge_path}")

      # Ensure dependencies are installed
      unless File.exists?(Path.join(bridge_path, "node_modules")) do
        Logger.info("[Bridge] Installing npm dependencies...")
        System.cmd("npm", ["install"], cd: bridge_path, stderr_to_stdout: true)
      end

      # Start the bridge as a port
      port = Port.open(
        {:spawn_executable, System.find_executable("npm")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: ["start"],
          cd: bridge_path,
          env: [
            {~c"NODE_ENV", ~c"production"},
            {~c"WHATSAPP_BRIDGE_PORT", ~c"3456"}
          ]
        ]
      )

      # Get the OS PID for the port
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      Logger.info("[Bridge] Started with OS PID #{os_pid}")
      {:reply, :ok, %{state | port: port, os_pid: os_pid}}
    end
  end

  def handle_call(:start_bridge, _from, state) do
    # Already running
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:stop_bridge, _from, %{port: nil} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:stop_bridge, _from, %{port: port, os_pid: os_pid} = state) do
    Logger.info("[Bridge] Stopping WhatsApp bridge (PID #{os_pid})")

    # Kill the process group to ensure child processes are also killed
    System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)

    # Close the port
    Port.close(port)

    {:reply, :ok, %{state | port: nil, os_pid: nil}}
  end

  @impl true
  def handle_call(:running?, _from, %{port: port} = state) do
    {:reply, port != nil, state}
  end

  @impl true
  def handle_call(:status, _from, %{port: port, os_pid: os_pid} = state) do
    process_running = port != nil

    # Check actual connection status via HTTP
    connection_status =
      if process_running do
        case PumaBot.WhatsApp.Client.status() do
          {:ok, status} -> status
          {:error, _} -> %{"connected" => false, "status" => "starting"}
        end
      else
        %{"connected" => false, "status" => "not_running"}
      end

    status = %{
      process_running: process_running,
      os_pid: os_pid,
      connected: connection_status["connected"] || connection_status[:connected] || false,
      status: connection_status["status"] || connection_status[:status] || "unknown",
      has_qr: connection_status["has_qr"] || connection_status[:has_qr] || false,
      buffered_messages: connection_status["buffered_messages"] || connection_status[:buffered_messages] || 0
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Log bridge output
    data
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)
      unless line == "" do
        Logger.debug("[Bridge] #{line}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[Bridge] Process exited with status #{status}")
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
