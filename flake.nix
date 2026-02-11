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

        CHROMIUM_EXECUTABLE = lib.getExe pkgs.chromium;

        # Agent template directory (copied into workspace at runtime)
        agentDir = ./agents/gemini;

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

          # Clone output directory — agent builds here
          mkdir -p clone
          ln -sfn ../recordings clone/recordings
          cd clone

          # Launch Gemini (use --yolo for non-interactive, omit for TUI)
          exec ${lib.getExe geminiCli} -m gemini-3.1-pro-preview "$@"
        '';
      in
      {
        packages = {
          agentBrowser = agentBrowser;
          gemini-cli = geminiCli;
          gemini-clone = geminiClone;
        };

        apps = {
          gemini-clone = {
            type = "app";
            program = lib.getExe geminiClone;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            virtualenv
            agentBrowser
            geminiCli
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
