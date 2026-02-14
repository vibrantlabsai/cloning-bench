# Claude Code CLI binary derivation
#
# Packages the pre-built Bun-based binary from Google Cloud Storage.
# Pattern follows llm-agents.nix's approach for claude-code packaging.
{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  bubblewrap,
  socat,
}:

let
  version = "2.1.42";

  platformMap = {
    "x86_64-linux" = "linux-x64";
    "aarch64-linux" = "linux-arm64";
    "x86_64-darwin" = "darwin-x64";
    "aarch64-darwin" = "darwin-arm64";
  };

  hashes = {
    "x86_64-linux" = "sha256-UXhb0m0oljloGYMrwjoYpsDKObe3YRk/p7bpkKF/J9g=";
    "aarch64-linux" = lib.fakeHash;
    "x86_64-darwin" = lib.fakeHash;
    "aarch64-darwin" = lib.fakeHash;
  };

  platform = stdenvNoCC.hostPlatform.system;
  platformSuffix = platformMap.${platform}
    or (throw "Unsupported platform: ${platform}");
in

stdenvNoCC.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/${platformSuffix}/claude";
    hash = hashes.${platform};
  };

  dontUnpack = true;
  dontStrip = true;

  nativeBuildInputs = [ makeWrapper ]
    ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    stdenv.cc.cc.lib # glibc
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/claude
    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/claude \
      --argv0 claude \
      --set DISABLE_AUTOUPDATER 1 \
      --set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1 \
      --set DISABLE_NON_ESSENTIAL_MODEL_CALLS 1 \
      --set DISABLE_TELEMETRY 1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      ${lib.optionalString stdenvNoCC.hostPlatform.isLinux
        "--prefix PATH : ${lib.makeBinPath [ bubblewrap socat ]}"
      }
  '';

  # macOS needs __noChroot for Bun's ICU data access
  __noChroot = stdenvNoCC.hostPlatform.isDarwin;

  meta = {
    description = "Claude Code - Anthropic's agentic coding tool for the terminal";
    homepage = "https://claude.ai/code";
    license = lib.licenses.unfree;
    mainProgram = "claude";
    platforms = builtins.attrNames platformMap;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
