#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  agent          Build the status agent (native)"
    echo "  agent-linux    Build the status agent for Linux x86_64"
    echo "  agent-windows  Build the status agent for Windows x86_64"
    echo "  agent-all      Build the status agent for all platforms"
    echo "  ca-bundle      Refresh the embedded CA root bundle from the system store"
    echo "  worker         Install worker dependencies"
    echo "  worker-dev     Run the worker locally (wrangler dev)"
    echo "  worker-deploy  Deploy the worker to Cloudflare"
    echo "  all            Build agent for all platforms + install worker deps"
    echo "  clean          Remove build artifacts"
}

case "${1:-}" in
    agent)
        echo "Building status agent (native)..."
        cd "$ROOT/agent" && zig build
        echo "Output: agent/zig-out/bin/status-agent"
        ;;
    agent-linux)
        echo "Building status agent for Linux x86_64..."
        cd "$ROOT/agent" && zig build linux
        echo "Output: agent/zig-out/bin/status-agent-linux-x86_64"
        ;;
    agent-windows)
        echo "Building status agent for Windows x86_64..."
        cd "$ROOT/agent" && zig build windows
        echo "Output: agent/zig-out/bin/status-agent-windows-x86_64.exe"
        ;;
    agent-all)
        echo "Building status agent for all platforms..."
        cd "$ROOT/agent" && zig build all
        echo "Outputs in agent/zig-out/bin/"
        ls -lh "$ROOT/agent/zig-out/bin/"
        ;;
    ca-bundle)
        echo "Refreshing embedded CA root bundle from /etc/ssl/certs/ca-certificates.crt..."
        {
            echo "# Mozilla CA root bundle (via Ubuntu ca-certificates), snapshot $(date -u +%Y-%m-%d)."
            echo "# Refresh with: ./build.sh ca-bundle"
            cat /etc/ssl/certs/ca-certificates.crt
        } > "$ROOT/agent/src/ca_bundle.pem"
        echo "Output: agent/src/ca_bundle.pem ($(grep -c 'BEGIN CERTIFICATE' "$ROOT/agent/src/ca_bundle.pem") roots)"
        ;;
    worker)
        echo "Installing worker dependencies..."
        cd "$ROOT/worker" && npm install
        ;;
    worker-dev)
        echo "Starting worker dev server..."
        cd "$ROOT/worker" && npx wrangler dev
        ;;
    worker-deploy)
        echo "Deploying worker to Cloudflare..."
        cd "$ROOT/worker" && npx wrangler deploy
        ;;
    all)
        echo "Building everything..."
        cd "$ROOT/agent" && zig build all
        cd "$ROOT/worker" && npm install
        echo "Done. Agent binaries in agent/zig-out/bin/"
        ;;
    clean)
        echo "Cleaning build artifacts..."
        rm -rf "$ROOT/agent/zig-out" "$ROOT/agent/.zig-cache"
        rm -rf "$ROOT/worker/node_modules"
        echo "Cleaned."
        ;;
    *)
        usage
        exit 1
        ;;
esac
