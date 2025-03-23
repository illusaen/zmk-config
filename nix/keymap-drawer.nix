{
  lib,
  buildPythonApplication,
  callPackage,
  fetchFromGitHub,
  poetry-core,
  pydantic,
  pcpp,
  pyyaml,
  platformdirs,
  pydantic-settings,
  tree-sitter,
  pyparsing,
}:
let
  tree-sitter-devicetree = callPackage ./tree-sitter-devicetree.nix { };
in
buildPythonApplication rec {
  pname = "keymap-drawer";
  version = "0.21.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "caksoylar";
    repo = pname;
    rev = "c7be1d5bf5aef69d47cc8a6106e5126794eb7311";
    hash = "sha256-LySpE9HFs2LnYgH/sOK1KOgkLuXTQyo0fEbir2mgxyI=";
  };

  postPatch = ''
    # nixos-unstable no longer bundles v23 of tree-sitter
    substituteInPlace pyproject.toml --replace-warn 'tree-sitter-devicetree ~= 0.14' 'tree-sitter (>=0.12.1,<0.25.0)'
  '';

  build-system = [ poetry-core ];

  propagatedBuildInputs = [
    pydantic
    pcpp
    pyyaml
    platformdirs
    pydantic-settings
    tree-sitter
    tree-sitter-devicetree
    pyparsing
  ];

  doCheck = false;

  meta = {
    homepage = "https://github.com/caksoylar/keymap-drawer";
    description = "Parse QMK & ZMK keymaps and draw them as vector graphics";
    license = lib.licenses.mit;
  };
}
