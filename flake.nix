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
