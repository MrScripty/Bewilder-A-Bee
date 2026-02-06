#!/usr/bin/env bash
#
# PumaBot Launcher
# ================
# Wrapper script for running the PumaBot Elixir application.
#
# Usage:
#   ./launcher.sh [command] [args...]
#
# Commands:
#   setup       - Set up PostgreSQL and database (first run)
#   server      - Start the Phoenix web server
#   iex         - Start interactive Elixir shell with app loaded
#   console     - Alias for iex
#   test        - Run tests
#   migrate     - Run database migrations
#   deps        - Fetch dependencies
#   compile     - Compile the project
#   clean       - Clean build artifacts
#   help        - Show this help message
#
# Environment Variables:
#   OLLAMA_HOST        - Ollama API URL (default: http://localhost:11434)
#   OLLAMA_CHAT_MODEL  - Chat model name (default: qwen3:latest)
#   OLLAMA_EMBED_MODEL - Embedding model name (default: nomic-embed-text)
#

set -e

# Script directory (where puma-bot lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Local PostgreSQL configuration
PGDATA="$SCRIPT_DIR/user/postgres"
PGLOG="$SCRIPT_DIR/user/logs/postgres.log"
PGPORT=5433  # Different port to avoid conflict with system PostgreSQL

# Find PostgreSQL binaries (they're often not in PATH on Ubuntu/Debian)
find_pg_bin() {
    # Check if already in PATH
    if command -v initdb &>/dev/null; then
        PG_BIN=""
        return 0
    fi

    # Search common locations
    for ver in 17 16 15 14 13; do
        if [ -d "/usr/lib/postgresql/$ver/bin" ]; then
            PG_BIN="/usr/lib/postgresql/$ver/bin/"
            return 0
        fi
    done

    # Not found
    PG_BIN=""
    return 1
}

# Initialize PG_BIN
find_pg_bin

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}$1${NC}"
}

# --- Environment Setup ---

setup_mise() {
    # Add mise to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Check if mise is installed
    if ! command -v mise &> /dev/null; then
        log_error "mise is not installed. Install it with: curl https://mise.run | sh"
        exit 1
    fi

    # Activate mise
    eval "$(mise activate bash)"
}

check_elixir() {
    if ! command -v elixir &> /dev/null; then
        log_error "Elixir is not available. Run: mise use -g elixir@latest"
        exit 1
    fi
}

# --- Local PostgreSQL Functions ---

check_postgres_tools() {
    # Check if PostgreSQL tools are installed
    if [ -n "$PG_BIN" ] && [ -x "${PG_BIN}initdb" ]; then
        return 0
    elif command -v initdb &>/dev/null; then
        return 0
    else
        return 1
    fi
}

check_local_postgres() {
    # Check if local PostgreSQL is running on our port
    ${PG_BIN}pg_isready -h localhost -p $PGPORT -q 2>/dev/null
}

init_local_postgres() {
    if [ ! -d "$PGDATA" ]; then
        log_info "Initializing local PostgreSQL cluster..."
        mkdir -p "$SCRIPT_DIR/user/logs"
        mkdir -p "$SCRIPT_DIR/user/run"
        ${PG_BIN}initdb -D "$PGDATA" --auth=trust --encoding=UTF8 --no-locale

        # Configure PostgreSQL to use local socket directory
        echo "" >> "$PGDATA/postgresql.conf"
        echo "# Local configuration" >> "$PGDATA/postgresql.conf"
        echo "unix_socket_directories = '$SCRIPT_DIR/user/run'" >> "$PGDATA/postgresql.conf"
        echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"

        log_success "PostgreSQL cluster initialized at $PGDATA"
    else
        log_info "PostgreSQL data directory already exists"
    fi
}

start_local_postgres() {
    if ! check_local_postgres; then
        log_info "Starting local PostgreSQL on port $PGPORT..."
        ${PG_BIN}pg_ctl -D "$PGDATA" -l "$PGLOG" -o "-p $PGPORT" start
        sleep 2
        if check_local_postgres; then
            log_success "Local PostgreSQL started"
        else
            log_error "Failed to start local PostgreSQL"
            log_info "Check logs at: $PGLOG"
            return 1
        fi
    else
        log_info "Local PostgreSQL is already running"
    fi
}

stop_local_postgres() {
    if check_local_postgres; then
        log_info "Stopping local PostgreSQL..."
        ${PG_BIN}pg_ctl -D "$PGDATA" stop -m fast
        log_success "Local PostgreSQL stopped"
    else
        log_info "Local PostgreSQL is not running"
    fi
}

check_postgres_user() {
    local username="${USER:-$(whoami)}"
    if psql -h localhost -p $PGPORT -U "$username" -d postgres -c "SELECT 1" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

check_pgvector() {
    # Check if pgvector package is installed
    if dpkg -l | grep -q "postgresql.*pgvector"; then
        return 0
    else
        return 1
    fi
}

# Legacy function for compatibility
check_postgres() {
    check_local_postgres
}

check_ollama() {
    local host="${OLLAMA_HOST:-http://localhost:11434}"
    if curl -s "$host/api/tags" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# --- Commands ---

cmd_setup() {
    echo ""
    echo "🐆 PumaBot Setup"
    echo "================"

    local username="${USER:-$(whoami)}"

    # Step 1: Check PostgreSQL tools
    log_step "📊 Step 1: PostgreSQL Tools"
    if ! check_postgres_tools; then
        log_info "PostgreSQL tools not installed. Installing..."
        sudo apt update
        sudo apt install -y postgresql postgresql-contrib
        # Re-find the binaries after installation
        find_pg_bin
        if ! check_postgres_tools; then
            log_error "Failed to install PostgreSQL tools"
            exit 1
        fi
        log_success "PostgreSQL tools installed"
    else
        log_success "PostgreSQL tools are available (${PG_BIN:-in PATH})"
    fi

    # Step 2: pgvector extension
    log_step "🔢 Step 2: pgvector Extension"
    if check_pgvector; then
        log_success "pgvector package is installed"
    else
        log_info "Installing pgvector extension..."
        sudo apt install -y postgresql-16-pgvector 2>/dev/null || \
        sudo apt install -y postgresql-15-pgvector 2>/dev/null || \
        sudo apt install -y postgresql-14-pgvector 2>/dev/null || \
        {
            log_error "Failed to install pgvector. Please install it manually."
            log_info "Try: sudo apt search pgvector"
            exit 1
        }
        log_success "pgvector installed"
    fi

    # Step 2.5: inotify-tools for live reload
    log_step "👁️  Step 2.5: inotify-tools (live reload)"
    if command -v inotifywait &>/dev/null; then
        log_success "inotify-tools is installed"
    else
        log_info "Installing inotify-tools for Phoenix live reload..."
        sudo apt install -y inotify-tools
        if command -v inotifywait &>/dev/null; then
            log_success "inotify-tools installed"
        else
            log_warn "Failed to install inotify-tools - live reload won't work"
        fi
    fi

    # Step 3: Initialize local PostgreSQL cluster
    log_step "🗄️  Step 3: Local PostgreSQL Cluster"
    init_local_postgres

    # Step 4: Start local PostgreSQL
    log_step "🚀 Step 4: Start Local PostgreSQL"
    start_local_postgres

    # Step 5: Database setup (via Elixir)
    log_step "📝 Step 5: Database Setup"
    log_info "Running database setup..."
    mix puma.setup

    echo ""
    log_success "Setup complete! You can now run:"
    echo "   ./launcher.sh run       # Start everything (recommended)"
    echo "   ./launcher.sh server    # Start web server only"
    echo "   ./launcher.sh iex       # Interactive shell"
    echo ""
    echo "Data is stored in: $SCRIPT_DIR/user/"
    echo "PostgreSQL port: $PGPORT"
    echo ""
}

cmd_server() {
    log_info "Starting Phoenix server..."

    if ! check_postgres; then
        log_error "PostgreSQL must be running. Run: ./launcher.sh setup"
        exit 1
    fi

    if ! check_ollama; then
        log_warn "Ollama is not running - LLM features will not work"
    fi

    mix phx.server
}

cmd_iex() {
    log_info "Starting IEx console..."

    if ! check_postgres; then
        log_warn "PostgreSQL is not running - database features unavailable"
    fi

    iex -S mix
}

cmd_test() {
    log_info "Running tests..."
    mix test "$@"
}

cmd_migrate() {
    log_info "Running migrations..."
    mix ecto.migrate
}

cmd_deps() {
    log_info "Fetching dependencies..."
    mix deps.get
}

cmd_compile() {
    log_info "Compiling project..."
    mix compile "$@"
}

cmd_clean() {
    log_info "Cleaning build artifacts..."
    mix clean
    rm -rf _build deps
    log_success "Cleaned"
}

cmd_status() {
    echo ""
    echo "🐆 PumaBot Status"
    echo "================="
    echo ""

    # Elixir version
    echo -n "Elixir: "
    if command -v elixir &> /dev/null; then
        elixir --version | grep "Elixir" | head -1
    else
        echo -e "${RED}Not installed${NC}"
    fi

    # Local PostgreSQL
    echo -n "PostgreSQL (local): "
    if [ ! -d "$PGDATA" ]; then
        echo -e "${RED}Not initialized${NC} (run: ./launcher.sh setup)"
    elif check_local_postgres; then
        echo -e "${GREEN}Running${NC} on port $PGPORT"
    else
        echo -e "${YELLOW}Stopped${NC} (run: ./launcher.sh db start)"
    fi

    # WhatsApp Bridge
    local bridge_url="${WHATSAPP_BRIDGE_URL:-http://localhost:3456}"
    echo -n "WhatsApp Bridge: "
    if curl -s "$bridge_url/api/status" > /dev/null 2>&1; then
        local buffered=$(curl -s "$bridge_url/api/status" | grep -o '"buffered_messages":[0-9]*' | cut -d: -f2)
        echo -e "${GREEN}Running${NC} ($buffered messages buffered)"
    else
        echo -e "${RED}Not running${NC}"
    fi

    # Ollama
    echo -n "Ollama: "
    if check_ollama; then
        echo -e "${GREEN}Running${NC}"
    else
        echo -e "${RED}Not running${NC}"
    fi

    echo ""

    # Data counts (if PostgreSQL is running)
    if check_local_postgres; then
        echo "📊 Data Counts:"
        local claude_count=$(psql -h localhost -p $PGPORT -U "${USER:-$(whoami)}" -d puma_bot_dev -t -c "SELECT COUNT(*) FROM claude_conversations;" 2>/dev/null | tr -d ' ')
        local whatsapp_count=$(psql -h localhost -p $PGPORT -U "${USER:-$(whoami)}" -d puma_bot_dev -t -c "SELECT COUNT(*) FROM whatsapp_messages;" 2>/dev/null | tr -d ' ')
        local datasource_count=$(psql -h localhost -p $PGPORT -U "${USER:-$(whoami)}" -d puma_bot_dev -t -c "SELECT COUNT(*) FROM data_sources;" 2>/dev/null | tr -d ' ')
        echo "   Claude conversations: ${claude_count:-0}"
        echo "   WhatsApp messages: ${whatsapp_count:-0}"
        echo "   Data sources (RAG): ${datasource_count:-0}"
        echo ""
    fi
}

cmd_import() {
    log_info "Running data import..."

    if ! check_postgres; then
        log_error "PostgreSQL must be running. Run: ./launcher.sh setup"
        exit 1
    fi

    mix puma.import "$@"
}

cmd_db() {
    local subcmd="${1:-status}"
    shift || true

    case "$subcmd" in
        init)
            init_local_postgres
            ;;
        start)
            start_local_postgres
            ;;
        stop)
            stop_local_postgres
            ;;
        status)
            echo ""
            echo "🗄️  Local PostgreSQL Status"
            echo "==========================="
            echo "Data directory: $PGDATA"
            echo "Log file: $PGLOG"
            echo "Port: $PGPORT"
            echo ""
            if [ -d "$PGDATA" ]; then
                echo -e "Data directory: ${GREEN}exists${NC}"
            else
                echo -e "Data directory: ${RED}not initialized${NC}"
                echo "Run: ./launcher.sh db init"
                return
            fi
            if check_local_postgres; then
                echo -e "Status: ${GREEN}running${NC}"
                echo ""
                echo "Connection string:"
                echo "  psql -h localhost -p $PGPORT puma_bot_dev"
            else
                echo -e "Status: ${RED}stopped${NC}"
                echo "Run: ./launcher.sh db start"
            fi
            echo ""
            ;;
        migrate)
            if ! check_local_postgres; then
                start_local_postgres
            fi
            log_info "Running migrations..."
            mix ecto.migrate
            ;;
        dump)
            local backup_file="${1:-backup.sql}"
            log_info "Dumping database to $backup_file..."
            ${PG_BIN}pg_dump -h localhost -p $PGPORT puma_bot_dev > "$backup_file"
            log_success "Database dumped to $backup_file"
            ;;
        restore)
            local backup_file="${1:-backup.sql}"
            if [ ! -f "$backup_file" ]; then
                log_error "Backup file not found: $backup_file"
                exit 1
            fi
            log_info "Restoring database from $backup_file..."
            psql -h localhost -p $PGPORT puma_bot_dev < "$backup_file"
            log_success "Database restored"
            ;;
        *)
            echo "Usage: ./launcher.sh db [command]"
            echo ""
            echo "Commands:"
            echo "  init    - Initialize local PostgreSQL cluster"
            echo "  start   - Start local PostgreSQL"
            echo "  stop    - Stop local PostgreSQL"
            echo "  status  - Show PostgreSQL status (default)"
            echo "  migrate - Run database migrations"
            echo "  dump    - Dump database to backup.sql"
            echo "  restore - Restore database from backup.sql"
            ;;
    esac
}

cmd_run() {
    echo ""
    echo "🐆 Starting PumaBot"
    echo "==================="
    echo ""

    # Track PIDs for cleanup
    WHATSAPP_PID=""

    cleanup() {
        echo ""
        log_info "Shutting down PumaBot..."

        # Stop WhatsApp bridge
        if [ -n "$WHATSAPP_PID" ] && kill -0 "$WHATSAPP_PID" 2>/dev/null; then
            log_info "Stopping WhatsApp Bridge..."
            kill "$WHATSAPP_PID" 2>/dev/null
        fi

        # Stop local PostgreSQL
        stop_local_postgres

        log_success "PumaBot stopped"
        exit 0
    }

    trap cleanup EXIT INT TERM

    # Step 1: Start local PostgreSQL
    log_step "Starting local PostgreSQL..."
    if [ ! -d "$PGDATA" ]; then
        init_local_postgres
    fi
    start_local_postgres

    # Step 2: Ensure database exists
    log_step "Checking database..."
    if ! psql -h localhost -p $PGPORT -U "${USER:-$(whoami)}" -lqt 2>/dev/null | grep -qw puma_bot_dev; then
        log_info "Database not found, running setup..."
        mix ecto.create
        mix ecto.migrate
        log_success "Database created and migrated"
    fi

    # Step 2: Start WhatsApp Bridge in background
    local bridge_dir="$SCRIPT_DIR/services/whatsapp-bridge"
    if [ -d "$bridge_dir" ]; then
        log_step "Starting WhatsApp Bridge..."
        if [ ! -d "$bridge_dir/node_modules" ]; then
            log_info "Installing Node.js dependencies..."
            (cd "$bridge_dir" && npm install)
        fi
        (cd "$bridge_dir" && npm start) &
        WHATSAPP_PID=$!
        sleep 3

        if kill -0 "$WHATSAPP_PID" 2>/dev/null; then
            log_success "WhatsApp Bridge started (PID: $WHATSAPP_PID)"
        else
            log_warn "WhatsApp Bridge failed to start"
            WHATSAPP_PID=""
        fi
    fi

    # Step 3: Start Elixir app with import daemon
    log_step "Starting Elixir application..."
    echo ""
    echo "┌────────────────────────────────────────────────────────┐"
    echo "│  PumaBot is running!                                   │"
    echo "│                                                        │"
    echo "│  PostgreSQL: localhost:$PGPORT                          │"
    echo "│  WhatsApp Bridge: http://localhost:3456                │"
    echo "│                                                        │"
    echo "│  Press Ctrl+C to stop all services                     │"
    echo "└────────────────────────────────────────────────────────┘"
    echo ""

    # Run iex with the app (this blocks until exit)
    iex -S mix
}

cmd_gui() {
    local port="${PHOENIX_PORT:-4000}"
    local url="http://localhost:$port"

    # Check if server is already running
    if curl -s "$url" > /dev/null 2>&1; then
        log_warn "Server already running on port $port, killing it..."
        # Find and kill the process
        local pid=$(lsof -ti :$port 2>/dev/null)
        if [ -n "$pid" ]; then
            kill $pid 2>/dev/null
            sleep 1
            # Force kill if still running
            if kill -0 $pid 2>/dev/null; then
                kill -9 $pid 2>/dev/null
            fi
            log_success "Killed existing server (PID: $pid)"
        fi
        sleep 1
    fi

    # Start PostgreSQL if needed
    if ! check_postgres; then
        log_info "Starting PostgreSQL..."
        start_local_postgres
    fi

    log_info "Starting Phoenix server..."

    # Start server in background
    MIX_ENV=dev mix phx.server &
    local server_pid=$!

    # Wait for server to be ready
    log_info "Waiting for server to be ready..."
    local attempts=0
    local max_attempts=30
    while [ $attempts -lt $max_attempts ]; do
        if curl -s "$url" > /dev/null 2>&1; then
            log_success "Server is ready!"
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    if [ $attempts -eq $max_attempts ]; then
        log_error "Server failed to start within ${max_attempts}s"
        kill $server_pid 2>/dev/null
        exit 1
    fi

    # Open browser
    log_info "Opening browser..."
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" 2>/dev/null &
    elif command -v open &> /dev/null; then
        open "$url" &
    else
        log_warn "Could not detect browser opener. Please open: $url"
    fi

    echo ""
    echo "┌────────────────────────────────────────────────────────┐"
    echo "│  PumaBot GUI running at: $url                    │"
    echo "│  Press Ctrl+C to stop                                  │"
    echo "└────────────────────────────────────────────────────────┘"
    echo ""

    # Wait for server process (blocks until Ctrl+C)
    wait $server_pid
}

cmd_whatsapp() {
    local subcmd="${1:-start}"
    shift || true

    local bridge_dir="$SCRIPT_DIR/services/whatsapp-bridge"

    case "$subcmd" in
        start)
            log_info "Starting WhatsApp Bridge..."

            # Check if node_modules exists
            if [ ! -d "$bridge_dir/node_modules" ]; then
                log_info "Installing Node.js dependencies..."
                (cd "$bridge_dir" && npm install)
            fi

            # Start the bridge
            (cd "$bridge_dir" && npm start)
            ;;
        install)
            log_info "Installing WhatsApp Bridge dependencies..."
            (cd "$bridge_dir" && npm install)
            log_success "Dependencies installed"
            ;;
        clean)
            log_info "Cleaning WhatsApp Bridge auth..."
            rm -rf "$bridge_dir/auth"
            log_success "Auth cleaned - you'll need to scan QR code again"
            ;;
        status)
            local bridge_url="${WHATSAPP_BRIDGE_URL:-http://localhost:3456}"
            if curl -s "$bridge_url/api/status" > /dev/null 2>&1; then
                echo -e "${GREEN}WhatsApp Bridge is running${NC}"
                curl -s "$bridge_url/api/status" | python3 -m json.tool 2>/dev/null || curl -s "$bridge_url/api/status"
            else
                echo -e "${RED}WhatsApp Bridge is not running${NC}"
                echo "Start with: ./launcher.sh whatsapp start"
            fi
            ;;
        *)
            echo "Usage: ./launcher.sh whatsapp [start|install|clean|status]"
            echo ""
            echo "Commands:"
            echo "  start   - Start the WhatsApp Bridge (shows QR code)"
            echo "  install - Install Node.js dependencies"
            echo "  clean   - Remove auth state (logout)"
            echo "  status  - Check bridge status"
            ;;
    esac
}

cmd_help() {
    cat << 'EOF'
🐆 PumaBot Launcher
==================

Usage: ./launcher.sh [command] [args...]

Commands:
  run         Start everything (PostgreSQL, WhatsApp Bridge, App) - RECOMMENDED
  setup       Set up PostgreSQL and database (run this first!)
  gui         Start GUI and open in browser (kills existing if running)
  db          Manage local PostgreSQL (start, stop, status, init)
  import      Import all data sources (Claude Code, WhatsApp, etc.)
  whatsapp    Manage WhatsApp Bridge (start, install, clean, status)
  server      Start the Phoenix web server
  iex         Start interactive Elixir shell with app loaded
  console     Alias for iex
  test        Run tests (pass additional args to mix test)
  migrate     Run database migrations
  deps        Fetch dependencies
  compile     Compile the project (--warnings-as-errors supported)
  clean       Clean build artifacts and dependencies
  status      Check status of all services
  help        Show this help message

Examples:
  ./launcher.sh setup           # First-time setup (creates local PostgreSQL)
  ./launcher.sh run             # Start everything with one command
  ./launcher.sh gui             # Start GUI and open in browser
  ./launcher.sh import          # Import all data sources
  ./launcher.sh import --status # Show import status
  ./launcher.sh db status       # Check local PostgreSQL status
  ./launcher.sh db start        # Start local PostgreSQL only
  ./launcher.sh whatsapp start  # Start WhatsApp bridge (scan QR)
  ./launcher.sh whatsapp status # Check WhatsApp connection
  ./launcher.sh server          # Start web server
  ./launcher.sh iex             # Interactive shell

Data Storage:
  PostgreSQL data: ./user/postgres/
  PostgreSQL logs: ./user/logs/postgres.log
  PostgreSQL port: 5433

Environment Variables:
  OLLAMA_HOST        Ollama API URL (default: http://localhost:11434)
  OLLAMA_CHAT_MODEL  Chat model (default: qwen3:latest)
  OLLAMA_EMBED_MODEL Embedding model (default: nomic-embed-text)

EOF
}

# --- Main ---

main() {
    # Set up environment
    setup_mise
    check_elixir

    # Parse command
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        run)
            cmd_run "$@"
            ;;
        setup)
            cmd_setup "$@"
            ;;
        db)
            cmd_db "$@"
            ;;
        import|i)
            cmd_import "$@"
            ;;
        whatsapp|wa)
            cmd_whatsapp "$@"
            ;;
        gui|g)
            cmd_gui "$@"
            ;;
        server|s)
            cmd_server "$@"
            ;;
        iex|console|c)
            cmd_iex "$@"
            ;;
        test|t)
            cmd_test "$@"
            ;;
        migrate|m)
            cmd_migrate "$@"
            ;;
        deps|d)
            cmd_deps "$@"
            ;;
        compile)
            cmd_compile "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
