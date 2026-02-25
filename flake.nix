{
  description = "Cloning Bench - benchmark for evaluating website cloning agents";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      # Load the uv workspace (system-independent)
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        inherit (pkgs) lib;

        pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
          python = pkgs.python312;
        }).overrideScope
          (
            nixpkgs.lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              editableOverlay
            ]
          );

        virtualenv = pythonSet.mkVirtualEnv "cloning-bench-dev-env" workspace.deps.all;

        # Non-editable Python env for Docker containers (no $REPO_ROOT paths)
        containerPythonSet = (pkgs.callPackage pyproject-nix.build.packages {
          python = pkgs.python312;
        }).overrideScope
          (
            nixpkgs.lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
            ]
          );
        containerVirtualenv = containerPythonSet.mkVirtualEnv "cloning-bench-container-env" workspace.deps.all;

        agentBrowser = pkgs.callPackage ./nix/agent-browser.nix { };

        geminiCli = pkgs.callPackage ./agents/gemini/nix { };

        codexCli = pkgs.callPackage ./agents/codex/nix { };

        claudeCli = pkgs.callPackage ./agents/claude/nix { };

        CHROMIUM_EXECUTABLE = lib.getExe pkgs.chromium;

        # Agent template directories (copied into workspace at runtime)
        agentDir = ./agents/gemini;
        codexAgentDir = ./agents/codex;
        claudeAgentDir = ./agents/claude;

        # --- Docker container infrastructure ---

        # Packages shared across all agent containers
        containerPathPkgs = [
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
          pkgs.gnugrep
          pkgs.tmux
          pkgs.ncurses
          containerVirtualenv
          agentBrowser
          pkgs.nodejs_24
          pkgs.chromium
          pkgs.ffmpeg
          pkgs.git
          pkgs.curl
          pkgs.which
        ];

        # Merge packages into a single env to avoid symlink collisions
        mkContainerEnv = name: extraPkgs: pkgs.buildEnv {
          name = "${name}-container-env";
          paths = containerPathPkgs ++ extraPkgs;
          ignoreCollisions = true;
        };

        commonContainerExtras = [
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.fakeNss
        ];

        # --- Gemini: entrypoint, image, launcher ---

        geminiEntrypoint = pkgs.writeShellScriptBin "gemini-clone-entrypoint" ''
          set -euo pipefail

          export PROMPT="$(cat /prompt.txt)"
          cd /workspace
          WORKSPACE_ROOT="$PWD"

          # Copy agent config (baked into image at /agent-config/)
          if [ ! -f GEMINI.md ]; then
            cp /agent-config/GEMINI.md ./
          fi
          if [ ! -d .gemini ]; then
            cp -r /agent-config/.gemini ./
            chmod -R u+w ./.gemini
          fi

          # Recordings are bind-mounted at /workspace/recordings (read-only)

          # Isolate Gemini global config
          export GEMINI_CLI_HOME="$WORKSPACE_ROOT/.gemini-home"
          mkdir -p "$GEMINI_CLI_HOME/.gemini"

          # Pre-configure auth, trust, tips
          if [ ! -f "$GEMINI_CLI_HOME/.gemini/settings.json" ]; then
            echo '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' > "$GEMINI_CLI_HOME/.gemini/settings.json"
          fi
          if [ ! -f "$GEMINI_CLI_HOME/.gemini/trustedFolders.json" ]; then
            echo "{\"$WORKSPACE_ROOT/clone\": \"TRUST_FOLDER\"}" > "$GEMINI_CLI_HOME/.gemini/trustedFolders.json"
          fi
          if [ ! -f "$GEMINI_CLI_HOME/.gemini/state.json" ]; then
            echo '{"tipsShown":1}' > "$GEMINI_CLI_HOME/.gemini/state.json"
          fi

          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"

          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Auto-continue watchdog: monitors Gemini session files for model completion
          # and sends a "continue" message when the model stops
          cat > /tmp/watchdog.sh << 'WATCHDOG'
#!/usr/bin/env bash
GEMINI_HOME="$GEMINI_CLI_HOME/.gemini"
CONTINUE_MSG="Continue iterating. Run site-test, analyze results, fix issues. Never stop."
LAST_MTIME=0

sleep 60  # Wait for initial startup

while true; do
          # Find most recently modified session file
          LATEST=$(find "$GEMINI_HOME" -name 'session-*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

          if [ -n "$LATEST" ]; then
            CURRENT_MTIME=$(stat -c %Y "$LATEST" 2>/dev/null || echo 0)
            NOW=$(date +%s)
            AGE=$((NOW - CURRENT_MTIME))

            # If session file is stale (>45s) and has a new mtime we haven't seen
            if [ "$AGE" -gt 45 ] && [ "$CURRENT_MTIME" -gt "$LAST_MTIME" ]; then
              # Check if last message type is "gemini" (model finished) or "error" (API error)
              LAST_TYPE=$(grep -o '"type":"[^"]*"' "$LATEST" | tail -1 | sed 's/.*"type":"\([^"]*\)"/\1/')
              if [ "$LAST_TYPE" = "gemini" ] || [ "$LAST_TYPE" = "error" ]; then
                LAST_MTIME=$CURRENT_MTIME
                sleep 5
                tmux send-keys -t agent -l "$CONTINUE_MSG"
                sleep 1
                tmux send-keys -t agent C-m
              fi
            fi
          fi
          sleep 15
done
WATCHDOG
          chmod +x /tmp/watchdog.sh

          # Start watchdog in background
          /tmp/watchdog.sh &

          exec tmux new-session -s agent \
            "${lib.getExe geminiCli} -m gemini-3.1-pro-preview --yolo \"\$PROMPT\""
        '';

        geminiContainerEnv = mkContainerEnv "gemini-clone" [ geminiCli ];

        geminiCloneImage = pkgs.dockerTools.buildLayeredImage {
          name = "cloning-bench/gemini-clone";
          tag = "latest";

          contents = commonContainerExtras ++ [
            geminiContainerEnv
            geminiEntrypoint
          ];

          extraCommands = ''
            mkdir -p tmp workspace root home/agent
            chmod 1777 tmp
            mkdir -p usr/bin && ln -sf ${pkgs.coreutils}/bin/env usr/bin/env
            mkdir -p agent-config
            cp ${agentDir}/GEMINI.md agent-config/
            cp -r ${agentDir}/.gemini agent-config/

            # Add non-root agent user for site-test's internal Claude subprocess
            mkdir -p etc
            rm -f etc/passwd etc/group
            cat > etc/passwd <<'PASSWD'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/var/empty:/bin/sh
agent:x:1000:1000:agent:/home/agent:/bin/sh
PASSWD
            cat > etc/group <<'GROUP'
root:x:0:
nobody:x:65534:
agent:x:1000:
GROUP
          '';

          config = {
            Entrypoint = [ "${geminiEntrypoint}/bin/gemini-clone-entrypoint" ];
            WorkingDir = "/workspace";
            Env = [
              "PATH=${geminiContainerEnv}/bin"
              "CHROMIUM_PATH=${CHROMIUM_EXECUTABLE}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              # Bedrock auth for site-test's internal Claude agent
              "AWS_BEARER_TOKEN_BEDROCK=BEDROCK_TOKEN_REMOVED"
              "CLAUDE_CODE_USE_BEDROCK=1"
              "AWS_REGION=us-east-1"
              "ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0"
            ];
          };
        };

        geminiClone = pkgs.writeShellScriptBin "gemini-clone" ''
          set -euo pipefail

          if [ -z "''${GEMINI_API_KEY:-}" ]; then
            echo "ERROR: GEMINI_API_KEY must be set" >&2
            exit 1
          fi

          WORKSPACE="''${1:-.}"
          shift || true
          mkdir -p "$WORKSPACE"
          WORKSPACE="$(cd "$WORKSPACE" && pwd)"

          PROMPT_FILE="$(pwd)/prompt.txt"
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"

          IMAGE="cloning-bench/gemini-clone:latest"

          if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "Loading Docker image $IMAGE..."
            docker load < ${geminiCloneImage}
          fi

          CONTAINER_NAME="gemini-clone-$(basename "$WORKSPACE")"

          exec docker run --rm -t \
            --name "$CONTAINER_NAME" \
            -v "$WORKSPACE:/workspace" \
            -v "$RECORDINGS_SRC:/workspace/recordings:ro" \
            -v "$PROMPT_FILE:/prompt.txt:ro" \
            --shm-size=2g \
            --cap-add SYS_ADMIN \
            -e GEMINI_API_KEY \
            "$IMAGE"
        '';

        # --- Codex: entrypoint, image, launcher ---

        codexEntrypoint = pkgs.writeShellScriptBin "codex-clone-entrypoint" ''
          set -euo pipefail

          export PROMPT="$(cat /prompt.txt)"
          cd /workspace
          WORKSPACE_ROOT="$PWD"

          # Copy agent config (baked into image at /agent-config/)
          if [ ! -f AGENTS.md ]; then
            cp /agent-config/AGENTS.md ./
          fi
          if [ ! -d .codex ]; then
            cp -r /agent-config/.codex ./
            chmod -R u+w ./.codex
          fi
          if [ ! -d .agents ]; then
            cp -r /agent-config/.agents ./
            chmod -R u+w ./.agents
          fi

          # Recordings are bind-mounted at /workspace/recordings (read-only)

          # Isolate Codex global config
          export CODEX_HOME="$WORKSPACE_ROOT/.codex-home"
          mkdir -p "$CODEX_HOME"

          # Pre-configure model migration notice (skip interactive prompt)
          if [ ! -f "$CODEX_HOME/config.toml" ]; then
            cat > "$CODEX_HOME/config.toml" << 'CODEXCFG'
[notice.model_migrations]
"gpt-5.2-codex" = "gpt-5.3-codex"
CODEXCFG
          fi

          # Authenticate with API key
          printenv OPENAI_API_KEY | ${lib.getExe codexCli} login --with-api-key

          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"

          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Auto-continue watchdog: monitors session files for task_complete events
          # and sends a "continue" message to the codex TUI when the model stops
          cat > /tmp/watchdog.sh << 'WATCHDOG'
#!/usr/bin/env bash
SESSIONS_DIR="$CODEX_HOME/sessions"
CONTINUE_MSG="Continue iterating. Run site-test, analyze results, fix issues. Never stop."
LAST_COMPLETE_COUNT=0

sleep 30  # Wait for initial startup

while true; do
          COMPLETE_COUNT=$(grep -r '"task_complete"' "$SESSIONS_DIR" 2>/dev/null | wc -l)
          if [ "$COMPLETE_COUNT" -gt "$LAST_COMPLETE_COUNT" ]; then
            LAST_COMPLETE_COUNT=$COMPLETE_COUNT
            # Model stopped — wait a moment for TUI to show input prompt, then send continue
            sleep 5
            tmux send-keys -t agent -l "$CONTINUE_MSG"
            sleep 1
            tmux send-keys -t agent C-m
          fi
          sleep 10
done
WATCHDOG
          chmod +x /tmp/watchdog.sh

          # Start watchdog in background
          /tmp/watchdog.sh &

          exec tmux new-session -s agent \
            "${lib.getExe codexCli} --model gpt-5.3-codex --dangerously-bypass-approvals-and-sandbox \"\$PROMPT\""
        '';

        codexContainerEnv = mkContainerEnv "codex-clone" [ codexCli ];

        codexCloneImage = pkgs.dockerTools.buildLayeredImage {
          name = "cloning-bench/codex-clone";
          tag = "latest";

          contents = commonContainerExtras ++ [
            codexContainerEnv
            codexEntrypoint
          ];

          extraCommands = ''
            mkdir -p tmp workspace root home/agent
            chmod 1777 tmp
            mkdir -p usr/bin && ln -sf ${pkgs.coreutils}/bin/env usr/bin/env
            mkdir -p agent-config
            cp ${codexAgentDir}/AGENTS.md agent-config/
            cp -r ${codexAgentDir}/.codex agent-config/
            cp -r ${codexAgentDir}/.agents agent-config/

            # Add non-root agent user for site-test's internal Claude subprocess
            mkdir -p etc
            rm -f etc/passwd etc/group
            cat > etc/passwd <<'PASSWD'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/var/empty:/bin/sh
agent:x:1000:1000:agent:/home/agent:/bin/sh
PASSWD
            cat > etc/group <<'GROUP'
root:x:0:
nobody:x:65534:
agent:x:1000:
GROUP
          '';

          config = {
            Entrypoint = [ "${codexEntrypoint}/bin/codex-clone-entrypoint" ];
            WorkingDir = "/workspace";
            Env = [
              "PATH=${codexContainerEnv}/bin"
              "CHROMIUM_PATH=${CHROMIUM_EXECUTABLE}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              # Bedrock auth for site-test's internal Claude agent
              "AWS_BEARER_TOKEN_BEDROCK=BEDROCK_TOKEN_REMOVED"
              "CLAUDE_CODE_USE_BEDROCK=1"
              "AWS_REGION=us-east-1"
              "ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0"
            ];
          };
        };

        codexClone = pkgs.writeShellScriptBin "codex-clone" ''
          set -euo pipefail

          if [ -z "''${OPENAI_API_KEY:-}" ]; then
            echo "ERROR: OPENAI_API_KEY must be set" >&2
            exit 1
          fi

          WORKSPACE="''${1:-.}"
          shift || true
          mkdir -p "$WORKSPACE"
          WORKSPACE="$(cd "$WORKSPACE" && pwd)"

          PROMPT_FILE="$(pwd)/prompt.txt"
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"

          IMAGE="cloning-bench/codex-clone:latest"

          if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "Loading Docker image $IMAGE..."
            docker load < ${codexCloneImage}
          fi

          CONTAINER_NAME="codex-clone-$(basename "$WORKSPACE")"

          exec docker run --rm -t \
            --name "$CONTAINER_NAME" \
            -v "$WORKSPACE:/workspace" \
            -v "$RECORDINGS_SRC:/workspace/recordings:ro" \
            -v "$PROMPT_FILE:/prompt.txt:ro" \
            --shm-size=2g \
            --cap-add SYS_ADMIN \
            -e OPENAI_API_KEY \
            "$IMAGE"
        '';

        # --- Claude: entrypoint, image, launcher ---

        claudeEntrypoint = pkgs.writeShellScriptBin "claude-clone-entrypoint" ''
          set -euo pipefail

          # Prevent nested-session detection when launched from within Claude Code
          unset CLAUDECODE 2>/dev/null || true

          export PROMPT="$(cat /prompt.txt)"
          cd /workspace
          WORKSPACE_ROOT="$PWD"

          # Copy agent config (baked into image at /agent-config/)
          if [ ! -f CLAUDE.md ]; then
            cp /agent-config/CLAUDE.md ./
          fi
          if [ ! -d .claude ]; then
            cp -r /agent-config/.claude ./
            chmod -R u+w ./.claude
          fi

          # Recordings are bind-mounted at /workspace/recordings (read-only)

          # Isolate Claude global config
          export CLAUDE_CONFIG_DIR="$WORKSPACE_ROOT/.claude-home"
          mkdir -p "$CLAUDE_CONFIG_DIR"

          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"

          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Write a wrapper script that runs claude in a loop
          # First run: fresh conversation with original prompt
          # Subsequent runs: continue the same conversation with --continue
          CLAUDE_BIN="${lib.getExe claudeCli}"
          cat > /tmp/run-claude.sh << RUNCLAUDE
#!/usr/bin/env bash
CONTINUE_MSG="Continue iterating. Run site-test, analyze results, fix issues. Never stop."

# First run with original prompt
$CLAUDE_BIN --dangerously-skip-permissions -p "\$PROMPT"

# Auto-continue loop: when claude exits, restart with --continue
while true; do
  sleep 5
  echo "[watchdog] Claude exited, restarting with --continue..."
  $CLAUDE_BIN --dangerously-skip-permissions --continue -p "\$CONTINUE_MSG"
done
RUNCLAUDE
          chmod +x /tmp/run-claude.sh

          exec tmux new-session -s agent /tmp/run-claude.sh
        '';

        claudeContainerEnv = mkContainerEnv "claude-clone" [ claudeCli ];

        claudeCloneImage = pkgs.dockerTools.buildLayeredImage {
          name = "cloning-bench/claude-clone";
          tag = "latest";

          contents = commonContainerExtras ++ [
            claudeContainerEnv
            claudeEntrypoint
          ];

          extraCommands = ''
            mkdir -p tmp workspace home/agent
            chmod 1777 tmp
            mkdir -p usr/bin && ln -sf ${pkgs.coreutils}/bin/env usr/bin/env
            mkdir -p agent-config
            cp ${claudeAgentDir}/CLAUDE.md agent-config/
            cp -r ${claudeAgentDir}/.claude agent-config/

            # Replace fakeNss passwd/group with versions that include non-root agent user
            mkdir -p etc
            rm -f etc/passwd etc/group
            cat > etc/passwd <<'PASSWD'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/var/empty:/bin/sh
agent:x:1000:1000:agent:/home/agent:/bin/sh
PASSWD
            cat > etc/group <<'GROUP'
root:x:0:
nobody:x:65534:
agent:x:1000:
GROUP
          '';

          config = {
            Entrypoint = [ "${claudeEntrypoint}/bin/claude-clone-entrypoint" ];
            WorkingDir = "/workspace";
            Env = [
              "PATH=${claudeContainerEnv}/bin"
              "CHROMIUM_PATH=${CHROMIUM_EXECUTABLE}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              "AWS_BEARER_TOKEN_BEDROCK=BEDROCK_TOKEN_REMOVED"
              "CLAUDE_CODE_USE_BEDROCK=1"
              "AWS_REGION=us-east-1"
              "ANTHROPIC_MODEL=us.anthropic.claude-opus-4-6-v1"
            ];
          };
        };

        claudeClone = pkgs.writeShellScriptBin "claude-clone" ''
          set -euo pipefail

          WORKSPACE="''${1:-.}"
          shift || true
          mkdir -p "$WORKSPACE"
          WORKSPACE="$(cd "$WORKSPACE" && pwd)"

          PROMPT_FILE="$(pwd)/prompt.txt"
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"

          IMAGE="cloning-bench/claude-clone:latest"

          if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "Loading Docker image $IMAGE..."
            docker load < ${claudeCloneImage}
          fi

          CONTAINER_NAME="claude-clone-$(basename "$WORKSPACE")"

          exec docker run --rm -t \
            --name "$CONTAINER_NAME" \
            -v "$WORKSPACE:/workspace" \
            -v "$RECORDINGS_SRC:/workspace/recordings:ro" \
            -v "$PROMPT_FILE:/prompt.txt:ro" \
            --shm-size=2g \
            --cap-add SYS_ADMIN \
            "$IMAGE"
        '';
        # Extract conversation transcripts from a workspace into transcripts/
        extractTranscripts = pkgs.writeShellScriptBin "extract-transcripts" ''
          set -euo pipefail

          if [ -z "''${1:-}" ]; then
            echo "Usage: extract-transcripts <workspace-dir>" >&2
            exit 1
          fi

          WORKSPACE="$(cd "$1" && pwd)"
          cd "$WORKSPACE"
          OUT="transcripts"

          # Fresh extraction each time
          rm -rf "$OUT"
          mkdir -p "$OUT"

          FOUND=0

          # --- Codex ---
          if [ -d .codex-home ]; then
            echo "Detected Codex workspace"
            mkdir -p "$OUT/codex/sessions"
            # Session rollout files (sessions/YYYY/MM/DD/*.jsonl)
            ${lib.getExe pkgs.findutils} .codex-home/sessions -name '*.jsonl' -exec cp {} "$OUT/codex/sessions/" \;
            # TUI debug log
            [ -f .codex-home/log/codex-tui.log ] && cp .codex-home/log/codex-tui.log "$OUT/codex/tui.log"
            # User prompt history
            [ -f .codex-home/history.jsonl ] && cp .codex-home/history.jsonl "$OUT/codex/"
            FOUND=1
          fi

          # --- Gemini ---
          if [ -d .gemini-home ]; then
            echo "Detected Gemini workspace"
            mkdir -p "$OUT/gemini/sessions"
            # Chat session files (nested under project hash)
            ${lib.getExe pkgs.findutils} .gemini-home -name 'session-*.json' -exec cp {} "$OUT/gemini/sessions/" \;
            # Tool output cache
            TOOL_OUT="$(${lib.getExe pkgs.findutils} .gemini-home -type d -name tool_output -print -quit 2>/dev/null || true)"
            if [ -n "$TOOL_OUT" ] && [ -d "$TOOL_OUT" ]; then
              cp -r "$TOOL_OUT" "$OUT/gemini/tool-output"
            fi
            # Logs index
            ${lib.getExe pkgs.findutils} .gemini-home -name 'logs.json' -exec cp {} "$OUT/gemini/" \;
            FOUND=1
          fi

          # --- Claude ---
          if [ -d .claude-home ]; then
            echo "Detected Claude workspace"
            mkdir -p "$OUT/claude/sessions"
            # Conversation JSONL files
            if [ -d .claude-home/projects ]; then
              ${lib.getExe pkgs.findutils} .claude-home/projects -name '*.jsonl' -exec cp {} "$OUT/claude/sessions/" \;
            fi
            # Debug logs
            if [ -d .claude-home/debug ]; then
              cp -r .claude-home/debug "$OUT/claude/debug"
            fi
            FOUND=1
          fi

          # --- Common artifacts ---
          # Session timeline
          [ -f session-timeline.log ] && cp session-timeline.log "$OUT/"

          # Site-test results (check both workspace root and clone/)
          SITE_TEST_FOUND=0
          for base in . clone; do
            for dir in "$base"/*_test/; do
              if [ -d "$dir" ]; then
                mkdir -p "$OUT/site-test-results"
                cp -r "$dir" "$OUT/site-test-results/"
                SITE_TEST_FOUND=1
              fi
            done
          done

          # Screenshot archive
          if [ -d screenshot-archive ]; then
            cp -r screenshot-archive "$OUT/screenshot-archive"
          fi

          if [ "$FOUND" -eq 0 ]; then
            echo "No agent state directories found in $WORKSPACE" >&2
            echo "Expected one of: .codex-home/, .gemini-home/, .claude-home/" >&2
            rm -rf "$OUT"
            exit 1
          fi

          # --- Token usage summary ---
          JQ="${lib.getExe pkgs.jq}"

          # Codex: extract from event_msg lines with type=token_count
          # total_token_usage is cumulative within a session but resets between sessions
          # So we take the last token_count event per session file and sum across sessions
          if [ -d "$OUT/codex/sessions" ] && ls "$OUT/codex/sessions/"*.jsonl >/dev/null 2>&1; then
            echo "Extracting Codex token usage..."
            # Get last token_count from each session, then sum
            (for f in "$OUT/codex/sessions/"*.jsonl; do
              $JQ -s '[.[] | select(.type == "event_msg" and .payload.type == "token_count")] | last | .payload.info.total_token_usage' "$f"
            done) | $JQ -s '{
              agent: "codex",
              model: "gpt-5.3-codex",
              sessions: length,
              input_tokens: (map(.input_tokens // 0) | add),
              cached_input_tokens: (map(.cached_input_tokens // 0) | add),
              output_tokens: (map(.output_tokens // 0) | add),
              reasoning_output_tokens: (map(.reasoning_output_tokens // 0) | add)
            }' > "$OUT/codex/token-summary.json"
            echo "  → codex/token-summary.json"
          fi

          # Gemini: extract from messages[].tokens in session JSON
          if [ -d "$OUT/gemini/sessions" ] && ls "$OUT/gemini/sessions/"*.json >/dev/null 2>&1; then
            echo "Extracting Gemini token usage..."
            # Sum tokens across all messages in all session files
            $JQ -s '
              [.[].messages[]? | select(.tokens != null) | .tokens] |
              {
                agent: "gemini",
                model: (first | .model // "unknown"),
                messages: length,
                input_tokens: (map(.input // 0) | add),
                output_tokens: (map(.output // 0) | add),
                cached_tokens: (map(.cached // 0) | add),
                thought_tokens: (map(.thoughts // 0) | add),
                tool_tokens: (map(.tool // 0) | add),
                total_tokens: (map(.total // 0) | add)
              }
            ' "$OUT/gemini/sessions/"*.json > "$OUT/gemini/token-summary.json" 2>/dev/null || true

            # Get model from first gemini message
            MODEL=$($JQ -r '[.messages[]? | select(.model != null) | .model] | first // "unknown"' "$OUT/gemini/sessions/"*.json 2>/dev/null | head -1)
            if [ -n "$MODEL" ] && [ "$MODEL" != "null" ]; then
              $JQ --arg model "$MODEL" '.model = $model' "$OUT/gemini/token-summary.json" > "$OUT/gemini/token-summary.json.tmp" && mv "$OUT/gemini/token-summary.json.tmp" "$OUT/gemini/token-summary.json"
            fi
            echo "  → gemini/token-summary.json"
          fi

          # Claude: extract from assistant message usage objects
          if [ -d "$OUT/claude/sessions" ] && ls "$OUT/claude/sessions/"*.jsonl >/dev/null 2>&1; then
            echo "Extracting Claude token usage..."
            $JQ -s '
              [.[] | select(.type == "assistant" and .message.usage != null) | .message.usage] |
              {
                agent: "claude",
                model: "claude-opus-4.6",
                api_calls: length,
                input_tokens: (map(.input_tokens // 0) | add),
                output_tokens: (map(.output_tokens // 0) | add),
                cache_creation_input_tokens: (map(.cache_creation_input_tokens // 0) | add),
                cache_read_input_tokens: (map(.cache_read_input_tokens // 0) | add)
              }
            ' "$OUT/claude/sessions/"*.jsonl > "$OUT/claude/token-summary.json" 2>/dev/null || true
            echo "  → claude/token-summary.json"
          fi

          # --- Cost report ---
          # Pricing per million tokens (USD)
          # Codex gpt-5.3-codex: $1.75 input, $0.175 cached, $14.00 output
          # Gemini 3 Pro Preview (<=200K): $2.00 input, $0.20 cached, $12.00 output (includes thinking)
          # Claude Opus 4.5/4.6: $5.00 input, $10.00 cache write (1h), $0.50 cache read, $25.00 output
          echo ""
          echo "Generating cost report..."

          COST_PARTS=""

          if [ -f "$OUT/codex/token-summary.json" ]; then
            COST_PARTS="$COST_PARTS$($JQ '{
              agent: .agent,
              model: .model,
              pricing: {
                input_per_mtok: 1.75,
                cached_input_per_mtok: 0.175,
                output_per_mtok: 14.00
              },
              tokens: {
                uncached_input: (.input_tokens - .cached_input_tokens),
                cached_input: .cached_input_tokens,
                output: .output_tokens,
                reasoning_output: .reasoning_output_tokens
              },
              cost: {
                uncached_input: (((.input_tokens - .cached_input_tokens) / 1000000) * 1.75 * 100 | round / 100),
                cached_input: ((.cached_input_tokens / 1000000) * 0.175 * 100 | round / 100),
                output: ((.output_tokens / 1000000) * 14.00 * 100 | round / 100),
                total: (
                  (((.input_tokens - .cached_input_tokens) / 1000000) * 1.75)
                  + ((.cached_input_tokens / 1000000) * 0.175)
                  + ((.output_tokens / 1000000) * 14.00)
                  | . * 100 | round | . / 100
                )
              }
            }' "$OUT/codex/token-summary.json")
"
          fi

          if [ -f "$OUT/gemini/token-summary.json" ]; then
            COST_PARTS="$COST_PARTS$($JQ '{
              agent: .agent,
              model: .model,
              pricing: {
                input_per_mtok: 2.00,
                cached_input_per_mtok: 0.20,
                output_per_mtok: 12.00
              },
              tokens: {
                uncached_input: (.input_tokens - .cached_tokens),
                cached_input: .cached_tokens,
                output: .output_tokens,
                thinking: .thought_tokens
              },
              cost: {
                uncached_input: (((.input_tokens - .cached_tokens) / 1000000) * 2.00 * 100 | round / 100),
                cached_input: ((.cached_tokens / 1000000) * 0.20 * 100 | round / 100),
                output_and_thinking: (((.output_tokens + .thought_tokens) / 1000000) * 12.00 * 100 | round / 100),
                total: (
                  (((.input_tokens - .cached_tokens) / 1000000) * 2.00)
                  + ((.cached_tokens / 1000000) * 0.20)
                  + (((.output_tokens + .thought_tokens) / 1000000) * 12.00)
                  | . * 100 | round | . / 100
                )
              }
            }' "$OUT/gemini/token-summary.json")
"
          fi

          if [ -f "$OUT/claude/token-summary.json" ]; then
            COST_PARTS="$COST_PARTS$($JQ '{
              agent: .agent,
              model: .model,
              pricing: {
                input_per_mtok: 5.00,
                cache_write_1h_per_mtok: 10.00,
                cache_read_per_mtok: 0.50,
                output_per_mtok: 25.00
              },
              tokens: {
                input: .input_tokens,
                cache_write: .cache_creation_input_tokens,
                cache_read: .cache_read_input_tokens,
                output: .output_tokens
              },
              cost: {
                input: ((.input_tokens / 1000000) * 5.00 * 100 | round / 100),
                cache_write: ((.cache_creation_input_tokens / 1000000) * 10.00 * 100 | round / 100),
                cache_read: ((.cache_read_input_tokens / 1000000) * 0.50 * 100 | round / 100),
                output: ((.output_tokens / 1000000) * 25.00 * 100 | round / 100),
                total: (
                  ((.input_tokens / 1000000) * 5.00)
                  + ((.cache_creation_input_tokens / 1000000) * 10.00)
                  + ((.cache_read_input_tokens / 1000000) * 0.50)
                  + ((.output_tokens / 1000000) * 25.00)
                  | . * 100 | round | . / 100
                )
              }
            }' "$OUT/claude/token-summary.json")
"
          fi

          if [ -n "$COST_PARTS" ]; then
            echo "$COST_PARTS" | $JQ -s '.' > "$OUT/cost-report.json"
            echo "  → cost-report.json"
          fi

          # Summary
          FILE_COUNT="$(${lib.getExe pkgs.findutils} "$OUT" -type f | wc -l)"
          TOTAL_SIZE="$(du -sh "$OUT" | cut -f1)"
          echo ""
          echo "Extracted to $WORKSPACE/transcripts/"
          echo "  $FILE_COUNT files, $TOTAL_SIZE total"

          # Print cost report
          if [ -f "$OUT/cost-report.json" ]; then
            echo ""
            $JQ -r '.[] | "  \(.agent) (\(.model)):",
              "    tokens: \(.tokens | to_entries | map("\(.key)=\(.value)") | join(", "))",
              "    cost:   \(.cost | to_entries | map("\(.key)=$\(.value)") | join(", "))",
              ""' "$OUT/cost-report.json"
          fi
        '';
      in
      {
        packages = {
          agentBrowser = agentBrowser;
          gemini-cli = geminiCli;
          gemini-clone = geminiClone;
          gemini-clone-image = geminiCloneImage;
          codex-cli = codexCli;
          codex-clone = codexClone;
          codex-clone-image = codexCloneImage;
          claude-cli = claudeCli;
          claude-clone = claudeClone;
          claude-clone-image = claudeCloneImage;
          extract-transcripts = extractTranscripts;
        };

        apps = {
          gemini-clone = {
            type = "app";
            program = lib.getExe geminiClone;
          };
          codex-clone = {
            type = "app";
            program = lib.getExe codexClone;
          };
          claude-clone = {
            type = "app";
            program = lib.getExe claudeClone;
          };
          extract-transcripts = {
            type = "app";
            program = lib.getExe extractTranscripts;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            virtualenv
            agentBrowser
            geminiCli
            codexCli
            claudeCli
          ] ++ (with pkgs; [
            uv
            chromium
            ffmpeg
            nodejs_24
            git
          ]);
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = pythonSet.python.interpreter;
            UV_PYTHON_DOWNLOADS = "never";
            CHROMIUM_PATH = CHROMIUM_EXECUTABLE;
          };
          shellHook = ''
            unset PYTHONPATH
            export REPO_ROOT=$(pwd)
          '';
        };
      }
    );
}
