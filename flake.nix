{
  description = "shared flake-parts template";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";

    zephyr = {
      # This pins the version of Zephyr used by ZMK.
      url = "github:zmkfirmware/zephyr/v4.1.0+zmk-fixes";
      flake = false;
    };

    # Zephyr sdk and toolchain.
    zephyr-nix = {
      url = "github:nix-community/zephyr-nix";
      inputs.zephyr.follows = "zephyr";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    just-flake.url = "github:illusaen/just-flake";
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks-nix,
      treefmt-nix,
      zephyr-nix,
      just-flake,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
        "aarch64-linux"
      ];

      imports = [
        git-hooks-nix.flakeModule
        treefmt-nix.flakeModule
        just-flake.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        let
          zephyr = zephyr-nix.packages.${system};
        in
        {
          just-flake.features = {
            treefmt.enable = true;
            zmk = {
              enable = true;
              justfile = ./zmk-just;
            };
          };
          treefmt = {
            settings.global = {
              on-unmatched = "debug";
              excludes = [
                ".git"
                "*.lock"
                ".gitignore"
              ];
            };
            programs.clang-format.enable = true;
            programs.nixfmt.enable = true;
          };

          pre-commit.settings.hooks = {
            treefmt = {
              enable = true;
              packageOverrides.treefmt = config.treefmt.build.wrapper;
            };
            clang-tidy.enable = true;
            deadnix.enable = true;
            statix.enable = true;
          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              ${config.pre-commit.installationScript}
              export ZMK_BUILD_DIR=$(pwd)/.build
              export ZMK_SRC_DIR=$(pwd)/zmk/app
            '';
            inputsFrom = [
              config.treefmt.build.devShell
              config.pre-commit.devShell
              config.just-flake.outputs.devShell
            ];
            packages = with pkgs; [
              cmake
              ninja
              python313Packages.yq
              keymap-drawer
              zephyr.pythonEnv
              zephyr.hosttools-nix
              (zephyr.sdk.override { targets = [ "arm-zephyr-eabi" ]; })
            ];
          };
        };
    };
}
