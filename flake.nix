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

        CHROMIUM_EXECUTABLE = pkgs.lib.getExe pkgs.chromium;
      in
      {
        packages.agentBrowser = agentBrowser;

        devShells.default = pkgs.mkShell {
          packages = [
            virtualenv
            agentBrowser
          ] ++ (with pkgs; [
            uv
            chromium
            ffmpeg
            nodejs_24
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
