# Codex CLI binary derivation
#
# Packages the pre-built Rust binary from GitHub releases.
# Unlike the Gemini CLI (Node.js), this is a native binary that
# only needs ELF patching on Linux.
{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  libcap,
  openssl,
  zlib,
}:

let
  version = "0.101.0";

  sources = {
    "x86_64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-6XMt47hw32o5zkukRplhDvWBhDlneTRX+O8R86WlgjY=";
    };
    "aarch64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-unknown-linux-gnu.tar.gz";
      hash = lib.fakeHash;
    };
    "x86_64-darwin" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-apple-darwin.tar.gz";
      hash = lib.fakeHash;
    };
    "aarch64-darwin" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-apple-darwin.tar.gz";
      hash = lib.fakeHash;
    };
  };

  platform = stdenvNoCC.hostPlatform.system;

  # Map Nix platform to the binary name inside the tarball
  binaryNames = {
    "x86_64-linux" = "codex-x86_64-unknown-linux-gnu";
    "aarch64-linux" = "codex-aarch64-unknown-linux-gnu";
    "x86_64-darwin" = "codex-x86_64-apple-darwin";
    "aarch64-darwin" = "codex-aarch64-apple-darwin";
  };
in

stdenvNoCC.mkDerivation {
  pname = "codex-cli";
  inherit version;

  src = fetchurl (sources.${platform}
    or (throw "Unsupported platform: ${platform}"));

  sourceRoot = ".";

  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    autoPatchelfHook
  ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    stdenv.cc.cc.lib # libstdc++, libgcc_s
    libcap           # libcap.so.2
    openssl          # libssl.so.3, libcrypto.so.3
    zlib             # libz.so.1
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ${binaryNames.${platform}} $out/bin/codex
    runHook postInstall
  '';

  meta = {
    description = "OpenAI Codex CLI - AI coding agent for the terminal";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
