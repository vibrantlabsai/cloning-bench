{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  autoPatchelfHook,
  makeWrapper,
  nodejs,
  pnpm,
  fetchPnpmDeps,
  pnpmConfigHook,
}:

let
  version = "0.9.0";

  src = fetchFromGitHub {
    owner = "vercel-labs";
    repo = "agent-browser";
    rev = "v${version}";
    hash = "sha256-KwwjPR4x/WwA/jWyv2EORWieQqHGoA/eDpQSBeiaUnQ=";
  };

  # Build the Rust CLI binary
  cli = rustPlatform.buildRustPackage {
    pname = "agent-browser-cli";
    inherit version src;

    sourceRoot = "${src.name}/cli";

    cargoHash = "sha256-WbVSazYTvoH8plEFzK3J9wP9F3mvu1T541T1llAo7Ko=";

    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      autoPatchelfHook
    ];

    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      stdenv.cc.cc.lib
    ];

    meta = {
      description = "Fast browser automation CLI for AI agents";
      license = lib.licenses.asl20;
    };
  };

in
stdenv.mkDerivation (finalAttrs: {
  pname = "agent-browser";
  inherit version src;

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
    makeWrapper
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-ajlazaN9vdQ/d0g3DshHaHL0f4S8TsCi1P1sc3hEBgc=";
    fetcherVersion = 3;
  };

  buildPhase = ''
    runHook preBuild

    # Build TypeScript
    pnpm run build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/agent-browser $out/bin

    # Copy built JS files and runtime dependencies
    cp -r dist $out/lib/agent-browser/
    cp -r node_modules $out/lib/agent-browser/
    cp -r scripts $out/lib/agent-browser/
    cp -r skills $out/lib/agent-browser/
    cp package.json $out/lib/agent-browser/

    # Create wrapper script that invokes the Rust CLI
    # The CLI spawns the daemon which needs to find node_modules
    makeWrapper ${cli}/bin/agent-browser $out/bin/agent-browser \
      --set AGENT_BROWSER_HOME "$out/lib/agent-browser" \
      --prefix PATH : ${nodejs}/bin

    runHook postInstall
  '';

  meta = {
    description = "Headless browser automation CLI for AI agents";
    homepage = "https://github.com/vercel-labs/agent-browser";
    license = lib.licenses.asl20;
    mainProgram = "agent-browser";
  };
})
