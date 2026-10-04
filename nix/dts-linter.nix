{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs_22,
  # Set to a devicetree-language-server derivation to override the LSP server
  # bundled in dts-linter's node_modules. See ./dts-lsp-server.nix.
  dts-lsp-server ? null,
}:
buildNpmPackage rec {
  pname = "dts-linter";
  version = "0.5.1";

  src = fetchFromGitHub {
    owner = "kylebonnici";
    repo = pname;
    rev = "6686678f90ca687a742100b86aa2091238181496";
    hash = "sha256-sFCMZXtTO1l9tP/srhMvo4JbhRkC3Gs24X6/VmABn5E=";
  };

  nodejs = nodejs_22;

  # Keep in sync with package-lock.json.
  npmDepsHash = "sha256-pQygRYs7uVKasuC4bMEgDcbr/zJJcHLDALeeJVS3n+4=";

  nativeBuildInputs = [makeWrapper];

  # Call esbuild directly instead of via esbuild.js to skip the license-checker
  # step, which requires network access.
  buildPhase = ''
    runHook preBuild
    mkdir -p dist
    ./node_modules/.bin/esbuild src/dts-linter.ts \
      --bundle \
      --format=cjs \
      --minify \
      --platform=node \
      --outfile=dist/dts-linter.js
    runHook postBuild
  '';

  # The bundle relies on require.resolve("devicetree-language-server/...") at
  # runtime, so node_modules must live next to the bundle file.
  installPhase = ''
    runHook preInstall

    modDir="$out/lib/node_modules/dts-linter"
    mkdir -p "$modDir"
    cp dist/dts-linter.js "$modDir/"
    cp -r node_modules "$modDir/"

    mkdir -p "$out/bin"
    makeWrapper "${nodejs_22}/bin/node" "$out/bin/dts-linter" \
      --add-flags "$modDir/dts-linter.js"

    runHook postInstall
  '';

  postInstall = lib.optionalString (dts-lsp-server != null) ''
    cp ${dts-lsp-server}/dist/server.js \
       $out/lib/node_modules/dts-linter/node_modules/devicetree-language-server/dist/server.js
  '';

  meta = {
    description = "Devicetree linter and formatter CLI";
    homepage = "https://github.com/kylebonnici/dts-linter";
    license = lib.licenses.asl20;
    mainProgram = "dts-linter";
  };
}
