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

        agentBrowser = pkgs.callPackage ./nix/agent-browser.nix { };

        geminiCli = pkgs.callPackage ./agents/gemini/nix { };

        codexCli = pkgs.callPackage ./agents/codex/nix { };

        claudeCli = pkgs.callPackage ./agents/claude/nix { };

        CHROMIUM_EXECUTABLE = lib.getExe pkgs.chromium;

        # Agent template directories (copied into workspace at runtime)
        agentDir = ./agents/gemini;
        codexAgentDir = ./agents/codex;
        claudeAgentDir = ./agents/claude;

        # Wrapper that sets up an isolated workspace and launches Gemini CLI
        geminiClone = pkgs.writeShellScriptBin "gemini-clone" ''
          set -euo pipefail

          # Validate API key
          if [ -z "''${GEMINI_API_KEY:-}" ]; then
            echo "ERROR: GEMINI_API_KEY must be set" >&2
            exit 1
          fi

          # Workspace is the first argument or current directory
          WORKSPACE="''${1:-.}"
          shift || true
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"
          mkdir -p "$WORKSPACE"
          cd "$WORKSPACE"
          WORKSPACE_ROOT="$PWD"

          # Copy agent context into workspace (mutable copies - Gemini writes to .gemini/)
          if [ ! -f GEMINI.md ]; then
            cp ${agentDir}/GEMINI.md ./GEMINI.md
          fi
          if [ ! -d .gemini ]; then
            cp -r ${agentDir}/.gemini ./.gemini
            chmod -R u+w ./.gemini
          fi

          # Provision recordings (idempotent)
          if [ ! -d recordings ] && [ -d "$RECORDINGS_SRC" ]; then
            cp -r "$RECORDINGS_SRC" ./recordings
            chmod -R u+w ./recordings
          fi

          # Isolate Gemini global config per workspace (at workspace root, not clone/)
          export GEMINI_CLI_HOME="$WORKSPACE_ROOT/.gemini-home"
          mkdir -p "$GEMINI_CLI_HOME"

          # Browser automation
          export CHROMIUM_PATH="${CHROMIUM_EXECUTABLE}"
          export AGENT_BROWSER_EXECUTABLE_PATH="${CHROMIUM_EXECUTABLE}"

          # Tools on PATH
          export PATH="${lib.makeBinPath [
            geminiCli
            virtualenv
            agentBrowser
            pkgs.nodejs_24
            pkgs.chromium
            pkgs.ffmpeg
            pkgs.jujutsu
            pkgs.git
          ]}:$PATH"

          # Pre-configure trust and yolo mode in GEMINI_CLI_HOME if not already set
          mkdir -p "$GEMINI_CLI_HOME/.gemini"
          if [ ! -f "$GEMINI_CLI_HOME/.gemini/trustedFolders.json" ]; then
            echo "{\"$WORKSPACE_ROOT/clone\": \"TRUST_FOLDER\"}" > "$GEMINI_CLI_HOME/.gemini/trustedFolders.json"
          fi

          # Screenshot archive for timelapse tracking (at workspace root)
          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"
          export SITE_TEST_ARCHIVE_PREFIX="gemini-3.1-pro-preview"

          # Clone output directory — agent builds here
          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Launch Gemini (use --yolo for non-interactive, omit for TUI)
          exec ${lib.getExe geminiCli} -m gemini-3.1-pro-preview "$@"
        '';

        # Wrapper that sets up an isolated workspace and launches Codex CLI
        codexClone = pkgs.writeShellScriptBin "codex-clone" ''
          set -euo pipefail

          # Validate API key
          if [ -z "''${OPENAI_API_KEY:-}" ]; then
            echo "ERROR: OPENAI_API_KEY must be set" >&2
            exit 1
          fi

          # Workspace is the first argument or current directory
          WORKSPACE="''${1:-.}"
          shift || true
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"
          mkdir -p "$WORKSPACE"
          cd "$WORKSPACE"
          WORKSPACE_ROOT="$PWD"

          # Copy agent context into workspace (mutable copies)
          if [ ! -f AGENTS.md ]; then
            cp ${codexAgentDir}/AGENTS.md ./AGENTS.md
          fi
          if [ ! -d .codex ]; then
            cp -r ${codexAgentDir}/.codex ./.codex
            chmod -R u+w ./.codex
          fi
          if [ ! -d .agents ]; then
            cp -r ${codexAgentDir}/.agents ./.agents
            chmod -R u+w ./.agents
          fi

          # Provision recordings (idempotent)
          if [ ! -d recordings ] && [ -d "$RECORDINGS_SRC" ]; then
            cp -r "$RECORDINGS_SRC" ./recordings
            chmod -R u+w ./recordings
          fi

          # Isolate Codex global config per workspace (at workspace root, not clone/)
          export CODEX_HOME="$WORKSPACE_ROOT/.codex-home"
          mkdir -p "$CODEX_HOME"

          # Browser automation
          export CHROMIUM_PATH="${CHROMIUM_EXECUTABLE}"
          export AGENT_BROWSER_EXECUTABLE_PATH="${CHROMIUM_EXECUTABLE}"

          # Tools on PATH
          export PATH="${lib.makeBinPath [
            codexCli
            virtualenv
            agentBrowser
            pkgs.nodejs_24
            pkgs.chromium
            pkgs.ffmpeg
            pkgs.jujutsu
            pkgs.git
          ]}:$PATH"

          # Authenticate with API key
          printenv OPENAI_API_KEY | ${lib.getExe codexCli} login --with-api-key

          # Screenshot archive for timelapse tracking (at workspace root)
          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"
          export SITE_TEST_ARCHIVE_PREFIX="gpt-5.3-codex"

          # Clone output directory — agent builds here
          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Launch Codex (use --full-auto for non-interactive, omit for TUI)
          exec ${lib.getExe codexCli} "$@"
        '';

        # Wrapper that sets up an isolated workspace and launches Claude Code
        claudeClone = pkgs.writeShellScriptBin "claude-clone" ''
          set -euo pipefail

          # Workspace is the first argument or current directory
          WORKSPACE="''${1:-.}"
          shift || true
          RECORDINGS_SRC="''${RECORDINGS_DIR:-$(pwd)/recordings}"
          mkdir -p "$WORKSPACE"
          cd "$WORKSPACE"
          WORKSPACE_ROOT="$PWD"

          # Copy agent context into workspace (mutable copies)
          if [ ! -f CLAUDE.md ]; then
            cp ${claudeAgentDir}/CLAUDE.md ./CLAUDE.md
          fi
          if [ ! -d .claude ]; then
            cp -r ${claudeAgentDir}/.claude ./.claude
            chmod -R u+w ./.claude
          fi

          # Provision recordings (idempotent)
          if [ ! -d recordings ] && [ -d "$RECORDINGS_SRC" ]; then
            cp -r "$RECORDINGS_SRC" ./recordings
            chmod -R u+w ./recordings
          fi

          # Isolate Claude global config per workspace (at workspace root, not clone/)
          export CLAUDE_CONFIG_DIR="$WORKSPACE_ROOT/.claude-home"
          mkdir -p "$CLAUDE_CONFIG_DIR"

          # Bedrock authentication
          export AWS_BEARER_TOKEN_BEDROCK="''${AWS_BEARER_TOKEN_BEDROCK:-BEDROCK_TOKEN_REMOVED}"
          export CLAUDE_CODE_USE_BEDROCK="''${CLAUDE_CODE_USE_BEDROCK:-1}"
          export AWS_REGION="''${AWS_REGION:-us-east-1}"
          export ANTHROPIC_MODEL="''${ANTHROPIC_MODEL:-us.anthropic.claude-opus-4-5-20251101-v1:0}"

          # Browser automation
          export CHROMIUM_PATH="${CHROMIUM_EXECUTABLE}"
          export AGENT_BROWSER_EXECUTABLE_PATH="${CHROMIUM_EXECUTABLE}"

          # Tools on PATH
          export PATH="${lib.makeBinPath [
            claudeCli
            virtualenv
            agentBrowser
            pkgs.nodejs_24
            pkgs.chromium
            pkgs.ffmpeg
            pkgs.jujutsu
            pkgs.git
          ]}:$PATH"

          # Screenshot archive for timelapse tracking (at workspace root)
          export SITE_TEST_ARCHIVE_DIR="$WORKSPACE_ROOT/screenshot-archive"
          export SITE_TEST_ARCHIVE_PREFIX="$ANTHROPIC_MODEL"

          # Clone output directory — agent builds here
          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Launch Claude Code (use --dangerously-skip-permissions for non-interactive,
          # or rely on pre-configured .claude/settings.local.json permissions)
          exec ${lib.getExe claudeCli} "$@"
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
              model: "gpt-5.2-codex",
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
                model: "claude-opus-4",
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
          # Codex gpt-5.2-codex: $1.75 input, $0.175 cached, $14.00 output
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
          codex-cli = codexCli;
          codex-clone = codexClone;
          claude-cli = claudeCli;
          claude-clone = claudeClone;
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
            jujutsu
            git
          ]);
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = pythonSet.python.interpreter;
            UV_PYTHON_DOWNLOADS = "never";
            CHROMIUM_PATH = CHROMIUM_EXECUTABLE;
            AGENT_BROWSER_EXECUTABLE_PATH = CHROMIUM_EXECUTABLE;
          };
          shellHook = ''
            unset PYTHONPATH
            export REPO_ROOT=$(pwd)
          '';
        };
      }
    );
}
