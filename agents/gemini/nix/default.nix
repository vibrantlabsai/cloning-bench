# Inline gemini-cli derivation
#
# Inspired by:
#   - nixpkgs/pkgs/by-name/ge/gemini-cli-bin/package.nix (base pattern)
#   - github.com/numtide/llm-agents.nix (ripgrep patching, auto-update disabling)
{
  lib,
  stdenvNoCC,
  fetchurl,
  nodejs,
  makeBinaryWrapper,
  ripgrep,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "gemini-cli";
  version = "0.28.1";

  src = fetchurl {
    url = "https://github.com/google-gemini/gemini-cli/releases/download/v${finalAttrs.version}/gemini.js";
    hash = "sha256-2A8IULClWdX3/dEOfr/Jv72r8NxvoYO0jNYeA4kim8s=";
  };

  dontUnpack = true;

  strictDeps = true;

  buildInputs = [ nodejs ];

  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    runHook preInstall

    install -D "$src" "$out/share/gemini-cli/gemini.js"

    # Disable auto-update by flipping schema defaults from true to false
    # v0.28+ uses enableAutoUpdate/enableAutoUpdateNotification (not disableAutoUpdate)
    sed -i '/enableAutoUpdate: {/,/}/ s/default: true/default: false/' \
      "$out/share/gemini-cli/gemini.js"
    sed -i '/enableAutoUpdateNotification: {/,/}/ s/default: true/default: false/' \
      "$out/share/gemini-cli/gemini.js"

    # Install default policy TOML files
    # The single-file release doesn't include these, but the policy engine
    # expects them at __dirname/policies/ (DEFAULT_CORE_POLICIES_DIR).
    # Without these, YOLO mode has no "allow all" rule and tools get denied.
    # Source: packages/core/src/policy/policies/ in the gemini-cli repo.
    mkdir -p "$out/share/gemini-cli/policies"
    cp ${./policies}/*.toml "$out/share/gemini-cli/policies/"

    # Create wrapper with node interpreter and ripgrep on PATH
    makeBinaryWrapper ${nodejs}/bin/node $out/bin/gemini \
      --add-flags "$out/share/gemini-cli/gemini.js" \
      --set GEMINI_MODEL "gemini-3-pro-preview" \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]}

    runHook postInstall
  '';

  meta = {
    description = "AI agent that brings the power of Gemini directly into your terminal";
    homepage = "https://github.com/google-gemini/gemini-cli";
    license = lib.licenses.asl20;
    mainProgram = "gemini";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
  };
})
