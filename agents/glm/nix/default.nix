# Pi coding agent CLI binary derivation
#
# Packages the pre-built Bun-based binary from GitHub releases.
# Pi is a terminal coding agent from badlogic/pi-mono, used here as
# the harness for GLM-based website cloning.
{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
}:

let
  version = "0.57.1";

  platformMap = {
    "x86_64-linux" = "linux-x64";
    "aarch64-linux" = "linux-arm64";
    "x86_64-darwin" = "darwin-arm64";
    "aarch64-darwin" = "darwin-arm64";
  };

  hashes = {
    "x86_64-linux" = "sha256-ghQwKFWi+oPRW0cGvI6L6Rommqy0lhTBSqc/0sKqZac=";
    "aarch64-linux" = lib.fakeHash;
    "x86_64-darwin" = lib.fakeHash;
    "aarch64-darwin" = lib.fakeHash;
  };

  platform = stdenvNoCC.hostPlatform.system;
  platformSuffix = platformMap.${platform}
    or (throw "Unsupported platform: ${platform}");
in

stdenvNoCC.mkDerivation {
  pname = "pi-coding-agent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/badlogic/pi-mono/releases/download/v${version}/pi-${platformSuffix}.tar.gz";
    hash = hashes.${platform};
  };

  sourceRoot = "pi";

  dontStrip = true;

  nativeBuildInputs = [ makeWrapper ]
    ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    stdenv.cc.cc.lib # glibc
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/pi $out/bin

    # Copy entire distribution (binary + WASM module + themes + supporting files)
    cp -r . $out/share/pi/
    chmod +x $out/share/pi/pi

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper $out/share/pi/pi $out/bin/pi \
      --set PI_OFFLINE 1
  '';

  # macOS needs __noChroot for Bun's ICU data access
  __noChroot = stdenvNoCC.hostPlatform.isDarwin;

  meta = {
    description = "Pi - minimal terminal coding agent (badlogic/pi-mono)";
    homepage = "https://github.com/badlogic/pi-mono";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = builtins.attrNames platformMap;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
