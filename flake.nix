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

        piCli = pkgs.callPackage ./agents/glm/nix { };

        CHROMIUM_EXECUTABLE = lib.getExe pkgs.chromium;

        # Agent template directories (copied into workspace at runtime)
        agentDir = ./agents/gemini;
        codexAgentDir = ./agents/codex;
        claudeAgentDir = ./agents/claude;
        glmAgentDir = ./agents/glm;

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
          # Font rendering: Chromium needs fontconfig + actual font files to
          # rasterize any text (including custom @font-face web fonts).
          # Without these, all text is invisible in headless screenshots.
          pkgs.fontconfig
          pkgs.liberation_ttf
        ];

        # Generate a fonts.conf that points fontconfig at the Nix store font paths
        containerFontsConf = pkgs.makeFontsConf {
          fontDirectories = [ pkgs.liberation_ttf ];
        };

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
          export NODE_OPTIONS="--max-old-space-size=16384"
          cd /workspace
          WORKSPACE_ROOT="$PWD"

          # Recordings are bind-mounted at /workspace/recordings (read-only)

          # Isolate Gemini global config
          export GEMINI_CLI_HOME="$WORKSPACE_ROOT/.gemini-home"
          mkdir -p "$GEMINI_CLI_HOME/.gemini"

          # Pre-configure auth (API key), trust, tips, loop detection
          if [ ! -f "$GEMINI_CLI_HOME/.gemini/settings.json" ]; then
            echo '{"security":{"auth":{"selectedType":"gemini-api-key"}},"tools":{"sandbox":false},"disableLoopDetection":true}' > "$GEMINI_CLI_HOME/.gemini/settings.json"
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

          # Copy agent config into clone/ (the actual CWD where Gemini runs).
          # Gemini CLI discovers GEMINI.md by walking up from CWD to the .git
          # root. Placing it here ensures it is found even if git init occurs.
          if [ ! -f GEMINI.md ]; then
            cp /agent-config/GEMINI.md ./
          fi
          if [ ! -d .gemini ]; then
            cp -r /agent-config/.gemini ./
            chmod -R u+w ./.gemini
          fi

          # Auto-continue watchdog: monitors Gemini session files for model completion
          # and sends a "continue" message when the model stops
          cat > /tmp/watchdog.sh << 'WATCHDOG'
#!/usr/bin/env bash
GEMINI_HOME="$GEMINI_CLI_HOME/.gemini"
CONTINUE_MSG="Continue iterating. Run site-test, analyze results, fix issues. Never stop."
LAST_NUDGE=0
STALE_THRESHOLD=120  # seconds before considering session stale

sleep 60  # Wait for initial startup

while true; do
          NOW=$(date +%s)

          # --- Crash recovery: if gemini node process died, restart it ---
          GEMINI_ALIVE=0
          for p in /proc/[0-9]*/cmdline; do
            if grep -q "gemini.js" "$p" 2>/dev/null; then
              GEMINI_ALIVE=1
              break
            fi
          done
          if [ "$GEMINI_ALIVE" -eq 0 ]; then
            echo "[watchdog] Gemini CLI process not found, restarting..." >&2
            sleep 5
            tmux send-keys -t agent "${lib.getExe geminiCli} -m gemini-3.1-pro-preview --yolo \"\$PROMPT\"" C-m 2>/dev/null
            sleep 30
            continue
          fi

          # --- Staleness detection ---
          LATEST=$(find "$GEMINI_HOME" -name 'session-*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

          if [ -n "$LATEST" ]; then
            CURRENT_MTIME=$(stat -c %Y "$LATEST" 2>/dev/null || echo 0)
            AGE=$((NOW - CURRENT_MTIME))
            SINCE_NUDGE=$((NOW - LAST_NUDGE))

            # Check if last message indicates completion or error
            LAST_TYPE=$(grep -o '"type":"[^"]*"' "$LATEST" | tail -1 | sed 's/.*"type":"\([^"]*\)"/\1/')
            NEEDS_NUDGE=0

            # Case 1: Session ended normally (model finished) or hit error
            if [ "$AGE" -gt 45 ]; then
              if [ "$LAST_TYPE" = "gemini" ] || [ "$LAST_TYPE" = "error" ]; then
                NEEDS_NUDGE=1
              fi
            fi

            # Case 2: Absolute staleness - session hasn't updated in STALE_THRESHOLD seconds
            # This catches API errors that don't write to session file
            if [ "$AGE" -gt "$STALE_THRESHOLD" ]; then
              NEEDS_NUDGE=1
            fi

            # Only nudge if we haven't nudged recently (avoid spamming)
            if [ "$NEEDS_NUDGE" -eq 1 ] && [ "$SINCE_NUDGE" -gt 60 ]; then
              TMUX_CONTENT=$(tmux capture-pane -t agent -p 2>/dev/null)

              # Check for loop detection dialog and dismiss it
              if echo "$TMUX_CONTENT" | grep -q "loop detection"; then
                echo "[watchdog] Loop detection dialog found, dismissing..." >&2
                LAST_NUDGE=$NOW
                tmux send-keys -t agent Down 2>/dev/null
                sleep 1
                tmux send-keys -t agent Enter 2>/dev/null
                sleep 3
              # Check if agent has an active spinner (esc to cancel) - do NOT interrupt
              elif echo "$TMUX_CONTENT" | grep -q "esc to cancel"; then
                echo "[watchdog] Agent has active spinner, skipping nudge (age=$AGE s)" >&2
              # Agent is idle at prompt - safe to nudge
              else
                echo "[watchdog] Nudging idle agent (age=$AGE s, type=$LAST_TYPE)" >&2
                LAST_NUDGE=$NOW
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
              "FONTCONFIG_FILE=${containerFontsConf}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              # Bedrock auth for site-test's internal Claude agent
              # AWS_BEARER_TOKEN_BEDROCK is passed via docker run -e at runtime
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
            -e AWS_BEARER_TOKEN_BEDROCK \
            "$IMAGE"
        '';

        # --- Codex: entrypoint, image, launcher ---

        codexEntrypoint = pkgs.writeShellScriptBin "codex-clone-entrypoint" ''
          set -euo pipefail

          export PROMPT="$(cat /prompt.txt)"
          cd /workspace
          WORKSPACE_ROOT="$PWD"

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

          # Copy agent config into clone/ (the actual CWD where Codex runs).
          # Codex discovers AGENTS.md relative to the Git root / CWD, so it
          # must be here — not in the parent /workspace/ directory.
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

          # Initialize a Git repo so Codex's project-root detection works
          # and it properly discovers AGENTS.md in this directory.
          if [ ! -d .git ]; then
            git init -q
            git add -A
            git commit -q -m "initial" --allow-empty
          fi

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
              "FONTCONFIG_FILE=${containerFontsConf}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              # Bedrock auth for site-test's internal Claude agent
              # AWS_BEARER_TOKEN_BEDROCK is passed via docker run -e at runtime
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
            -e AWS_BEARER_TOKEN_BEDROCK \
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

          # Recordings are bind-mounted at /workspace/recordings (read-only)

          # Isolate Claude global config
          export CLAUDE_CONFIG_DIR="$WORKSPACE_ROOT/.claude-home"
          mkdir -p "$CLAUDE_CONFIG_DIR"

          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"

          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Copy agent config into clone/ (the actual CWD where Claude runs).
          # Claude Code discovers CLAUDE.md relative to the Git root / CWD.
          if [ ! -f CLAUDE.md ]; then
            cp /agent-config/CLAUDE.md ./
          fi
          if [ ! -d .claude ]; then
            cp -r /agent-config/.claude ./
            chmod -R u+w ./.claude
          fi

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
              "FONTCONFIG_FILE=${containerFontsConf}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              # AWS_BEARER_TOKEN_BEDROCK is passed via docker run -e at runtime
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
            -e AWS_BEARER_TOKEN_BEDROCK \
            "$IMAGE"
        '';

        # --- GLM (Pi harness): entrypoint, image, launcher ---

        glmEntrypoint = pkgs.writeShellScriptBin "glm-clone-entrypoint" ''
          set -euo pipefail

          export PROMPT="$(cat /prompt.txt)"
          export NODE_OPTIONS="--max-old-space-size=16384"
          cd /workspace
          WORKSPACE_ROOT="$PWD"

          # Recordings are bind-mounted at /workspace/recordings (read-only)

          # Isolate Pi global config
          export PI_CODING_AGENT_DIR="$WORKSPACE_ROOT/.pi-home"
          mkdir -p "$PI_CODING_AGENT_DIR"

          # Configure Fireworks provider for GLM-5
          cat > "$PI_CODING_AGENT_DIR/models.json" << 'MODELS'
{"providers":{"fireworks":{"baseUrl":"https://api.fireworks.ai/inference/v1","api":"openai-completions","apiKey":"FIREWORKS_KEY_PLACEHOLDER","models":[{"id":"accounts/fireworks/models/glm-5","name":"GLM-5","reasoning":true,"input":["text"],"contextWindow":203000,"maxTokens":16384,"cost":{"input":0.72,"output":2.30,"cacheRead":0.36,"cacheWrite":0}}]}}}
MODELS
          # Inject actual API key (heredoc is single-quoted to avoid shell expansion of JSON)
          sed -i "s/FIREWORKS_KEY_PLACEHOLDER/$FIREWORKS_API_KEY/" "$PI_CODING_AGENT_DIR/models.json"

          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"

          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Copy agent config into clone/ (the actual CWD where Pi runs).
          # Pi discovers AGENTS.md by walking up from CWD to the .git root.
          if [ ! -f AGENTS.md ]; then
            cp /agent-config/AGENTS.md ./
          fi
          if [ ! -d .pi ]; then
            cp -r /agent-config/.pi ./
            chmod -R u+w ./.pi
          fi

          # Initialize a Git repo so Pi's project-root detection works
          if [ ! -d .git ]; then
            git config --global user.email "agent@cloning-bench"
            git config --global user.name "Agent"
            git init -q
            git add -A
            git commit -q -m "initial" --allow-empty
          fi

          # Auto-continue watchdog: monitors Pi session files for staleness
          # and sends a "continue" message when the model stops.
          #
          # Two thresholds:
          #   STALE_THRESHOLD (120s) — nudge if idle at prompt (no spinner)
          #   FORCE_THRESHOLD (300s) — force-abort via Escape even if spinner is
          #     showing, because Pi's bash tool can get stuck on backgrounded
          #     processes (e.g. `npm run dev &`)
          cat > /tmp/watchdog.sh << 'WATCHDOG'
#!/usr/bin/env bash
PI_HOME="$PI_CODING_AGENT_DIR"
CONTINUE_MSG="Continue iterating. Run site-test, analyze results, fix issues. Never stop."
LAST_NUDGE=0
STALE_THRESHOLD=120   # seconds — soft threshold (only nudge if no spinner)
FORCE_THRESHOLD=180   # seconds — hard threshold (send Escape + nudge regardless)

sleep 60  # Wait for initial startup

while true; do
          NOW=$(date +%s)

          # --- Crash recovery: if pi process died, restart it ---
          PI_ALIVE=0
          for p in /proc/[0-9]*/cmdline; do
            if grep -q "pi" "$p" 2>/dev/null && ! grep -q "watchdog" "$p" 2>/dev/null; then
              PI_ALIVE=1
              break
            fi
          done
          if [ "$PI_ALIVE" -eq 0 ]; then
            echo "[watchdog] Pi process not found, restarting..." >&2
            sleep 5
            tmux send-keys -t agent "${lib.getExe piCli} --provider fireworks --model accounts/fireworks/models/glm-5 \"\$PROMPT\"" C-m 2>/dev/null
            sleep 30
            continue
          fi

          # --- Staleness detection ---
          LATEST=$(find "$PI_HOME/sessions" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

          if [ -n "$LATEST" ]; then
            CURRENT_MTIME=$(stat -c %Y "$LATEST" 2>/dev/null || echo 0)
            AGE=$((NOW - CURRENT_MTIME))
            SINCE_NUDGE=$((NOW - LAST_NUDGE))

            # Only act if we haven't nudged recently (avoid spamming)
            if [ "$SINCE_NUDGE" -gt 60 ]; then
              TMUX_CONTENT=$(tmux capture-pane -t agent -p 2>/dev/null)
              HAS_SPINNER=0
              if echo "$TMUX_CONTENT" | grep -qE "⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|Working"; then
                HAS_SPINNER=1
              fi

              # Check if a long-running but legitimate command is active
              # (site-test, agent-browser, chromium can take many minutes)
              LONG_CMD_ACTIVE=0
              if pgrep -f "site-test|agent-browser|chromium" >/dev/null 2>&1; then
                LONG_CMD_ACTIVE=1
              fi

              if [ "$AGE" -gt "$FORCE_THRESHOLD" ] && [ "$LONG_CMD_ACTIVE" -eq 0 ]; then
                # Hard threshold: Pi has been stuck for too long with no
                # legitimate long-running process active.  This happens when
                # Pi's bash tool hangs on a backgrounded process (e.g.
                # `npm run dev &`).  Send Escape to abort, then nudge.
                echo "[watchdog] FORCE abort - session stale $AGE s (>$FORCE_THRESHOLD s), sending Escape + continue" >&2
                LAST_NUDGE=$NOW
                tmux send-keys -t agent Escape 2>/dev/null
                sleep 5
                tmux send-keys -t agent -l "$CONTINUE_MSG"
                sleep 1
                tmux send-keys -t agent C-m

              elif [ "$AGE" -gt "$FORCE_THRESHOLD" ] && [ "$LONG_CMD_ACTIVE" -eq 1 ]; then
                echo "[watchdog] Stale $AGE s but long-running command active, skipping force abort" >&2

              elif [ "$AGE" -gt "$STALE_THRESHOLD" ] && [ "$HAS_SPINNER" -eq 0 ]; then
                # Soft threshold: session is stale and no spinner visible - Pi
                # is likely idle at its input prompt.
                echo "[watchdog] Nudging idle agent (age=$AGE s, no spinner)" >&2
                LAST_NUDGE=$NOW
                tmux send-keys -t agent -l "$CONTINUE_MSG"
                sleep 1
                tmux send-keys -t agent C-m

              elif [ "$AGE" -gt "$STALE_THRESHOLD" ] && [ "$HAS_SPINNER" -eq 1 ]; then
                echo "[watchdog] Spinner visible but stale $AGE s - waiting for force threshold ($FORCE_THRESHOLD s)" >&2
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
            "${lib.getExe piCli} --provider fireworks --model accounts/fireworks/models/glm-5 \"\$PROMPT\""
        '';

        glmContainerEnv = mkContainerEnv "glm-clone" [ piCli ];

        glmCloneImage = pkgs.dockerTools.buildLayeredImage {
          name = "cloning-bench/glm-clone";
          tag = "latest";

          contents = commonContainerExtras ++ [
            glmContainerEnv
            glmEntrypoint
          ];

          extraCommands = ''
            mkdir -p tmp workspace root home/agent
            chmod 1777 tmp
            mkdir -p usr/bin && ln -sf ${pkgs.coreutils}/bin/env usr/bin/env
            mkdir -p agent-config
            cp ${glmAgentDir}/AGENTS.md agent-config/
            cp -r ${glmAgentDir}/.pi agent-config/

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
            Entrypoint = [ "${glmEntrypoint}/bin/glm-clone-entrypoint" ];
            WorkingDir = "/workspace";
            Env = [
              "PATH=${glmContainerEnv}/bin"
              "CHROMIUM_PATH=${CHROMIUM_EXECUTABLE}"
              "FONTCONFIG_FILE=${containerFontsConf}"

              "HOME=/root"
              "TERM=xterm-256color"
              "AGENT_BROWSER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-gpu,--disable-dev-shm-usage"
              "IS_SANDBOX=1"
              # Bedrock auth for site-test's internal Claude agent
              # AWS_BEARER_TOKEN_BEDROCK is passed via docker run -e at runtime
              "CLAUDE_CODE_USE_BEDROCK=1"
              "AWS_REGION=us-east-1"
              "ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0"
            ];
          };
        };

        glmClone = pkgs.writeShellScriptBin "glm-clone" ''
          set -euo pipefail

          if [ -z "''${FIREWORKS_API_KEY:-}" ]; then
            echo "ERROR: FIREWORKS_API_KEY must be set" >&2
            exit 1
          fi

          WORKSPACE="''${1:-.}"
          shift || true
          mkdir -p "$WORKSPACE"
          WORKSPACE="$(cd "$WORKSPACE" && pwd)"

          PROMPT_FILE="$(pwd)/prompt.txt"
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"

          IMAGE="cloning-bench/glm-clone:latest"

          if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "Loading Docker image $IMAGE..."
            docker load < ${glmCloneImage}
          fi

          CONTAINER_NAME="glm-clone-$(basename "$WORKSPACE")"

          exec docker run --rm -t \
            --name "$CONTAINER_NAME" \
            -v "$WORKSPACE:/workspace" \
            -v "$RECORDINGS_SRC:/workspace/recordings:ro" \
            -v "$PROMPT_FILE:/prompt.txt:ro" \
            --shm-size=2g \
            --cap-add SYS_ADMIN \
            -e FIREWORKS_API_KEY \
            -e GEMINI_API_KEY \
            -e AWS_BEARER_TOKEN_BEDROCK \
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

          # --- GLM (Pi) ---
          if [ -d .pi-home ]; then
            echo "Detected GLM/Pi workspace"
            mkdir -p "$OUT/glm/sessions"
            # Session JSONL files (organized by working directory path)
            ${lib.getExe pkgs.findutils} .pi-home/sessions -name '*.jsonl' -exec cp {} "$OUT/glm/sessions/" \; 2>/dev/null || true
            # Global settings and models config
            [ -f .pi-home/settings.json ] && cp .pi-home/settings.json "$OUT/glm/"
            [ -f .pi-home/models.json ] && cp .pi-home/models.json "$OUT/glm/"
            FOUND=1
          fi

          # --- Common artifacts ---
          # Session timeline
          [ -f session-timeline.log ] && cp session-timeline.log "$OUT/"

          # Site-test results (find all *_test directories anywhere in workspace)
          SITE_TEST_FOUND=0
          while IFS= read -r dir; do
            mkdir -p "$OUT/site-test-results"
            cp -r "$dir" "$OUT/site-test-results/"
            SITE_TEST_FOUND=1
          done < <(${lib.getExe pkgs.findutils} . -maxdepth 5 -type d -name '*_test' ! -path './transcripts/*' ! -path './.*/sessions/*' 2>/dev/null)

          # Screenshot archive
          if [ -d screenshot-archive ]; then
            cp -r screenshot-archive "$OUT/screenshot-archive"
          fi

          if [ "$FOUND" -eq 0 ]; then
            echo "No agent state directories found in $WORKSPACE" >&2
            echo "Expected one of: .codex-home/, .gemini-home/, .claude-home/, .pi-home/" >&2
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

          # GLM/Pi: extract from assistant message usage objects in session JSONL
          if [ -d "$OUT/glm/sessions" ] && ls "$OUT/glm/sessions/"*.jsonl >/dev/null 2>&1; then
            echo "Extracting GLM/Pi token usage..."
            # Extract model name from session data (model_change event or first assistant message)
            PI_MODEL=$($JQ -r 'select(.type == "model_change") | "\(.provider)/\(.modelId)"' "$OUT/glm/sessions/"*.jsonl 2>/dev/null | tail -1)
            if [ -z "$PI_MODEL" ] || [ "$PI_MODEL" = "null" ]; then
              PI_MODEL=$($JQ -r 'select(.type == "message" and .message.model != null) | .message.model' "$OUT/glm/sessions/"*.jsonl 2>/dev/null | head -1)
            fi
            PI_MODEL="''${PI_MODEL:-unknown}"

            $JQ -s --arg model "$PI_MODEL" '
              [.[] | select(.type == "message" and .message.role == "assistant" and .message.usage != null) | .message.usage] |
              {
                agent: "glm",
                model: $model,
                api_calls: length,
                input_tokens: (map(.input // .inputTokens // 0) | add),
                output_tokens: (map(.output // .outputTokens // 0) | add),
                total_cost: (map(.cost.total // 0) | add)
              }
            ' "$OUT/glm/sessions/"*.jsonl > "$OUT/glm/token-summary.json" 2>/dev/null || true
            echo "  → glm/token-summary.json"
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

          if [ -f "$OUT/glm/token-summary.json" ]; then
            COST_PARTS="$COST_PARTS$($JQ '{
              agent: .agent,
              model: .model,
              tokens: {
                input: .input_tokens,
                output: .output_tokens
              },
              cost: {
                total_from_provider: (.total_cost * 100 | round / 100),
                total: (.total_cost * 100 | round / 100
                )
              }
            }' "$OUT/glm/token-summary.json")
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
          pi-cli = piCli;
          glm-clone = glmClone;
          glm-clone-image = glmCloneImage;
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
          glm-clone = {
            type = "app";
            program = lib.getExe glmClone;
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
            piCli
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
