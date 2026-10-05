{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # This pins requirements.txt provided by zephyr-nix.pythonEnv.
    zephyr.url = "github:zmkfirmware/zephyr/v4.1.0+zmk-fixes";
    zephyr.flake = false;

    # Zephyr sdk and toolchain.
    zephyr-nix.url = "github:nix-community/zephyr-nix";
    zephyr-nix.inputs.zephyr.follows = "zephyr";
    zephyr-nix.inputs.nixpkgs.follows = "nixpkgs";

    # West manifest locking; skipping the flake to build its package.nix with
    # our own nixpkgs and python package set.
    pin-west = {
      url = "github:urob/pin-west";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    abort-on-warn = false;
    extra-deprecated-features = ["broken-string-escape"];
  };

  outputs = {
    nixpkgs,
    devshell,
    treefmt-nix,
    zephyr-nix,
    pin-west,
    self,
    ...
  }: let
    inherit (nixpkgs) lib;

    systemContexts = lib.genAttrs ["x86_64-linux" "aarch64-linux"] (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [devshell.overlays.default pin-west.overlays.default];
        config.allowUnfree = true;
      };
    in {
      inherit pkgs system;
      zephyr = zephyr-nix.packages.${system};
      treefmt = treefmt-nix.lib.evalModule pkgs {
        projectRootFile = "flake.nix";
        programs.alejandra.enable = true;
        programs.deadnix.enable = true;
        programs.statix.enable = true;
        programs.nixf-diagnose.enable = true;
        settings.excludes = ["*.patch" "*.png" "*.jpeg"];
        settings.formatter.dts-format = let
          dts-format = pkgs.callPackage ./nix/dts-format.nix {
            dts-linter = pkgs.callPackage ./nix/dts-linter.nix {};
          };
        in {
          command = "${lib.getExe dts-format}";
          options = ["--fix" "--tab-width=2"];
          includes = ["*.dtsi" "*.dts" "*.overlay" "*.keymap"];
        };
      };
    });

    forAllSystems = f: lib.mapAttrs (_system: f) systemContexts;
  in {
    checks = forAllSystems ({treefmt, ...}: {
      treefmt = treefmt.config.build.check self;
    });
    formatter = forAllSystems ({treefmt, ...}: treefmt.config.build.wrapper);
    devShells = forAllSystems ({
      pkgs,
      treefmt,
      zephyr,
      ...
    }: let
      zephyrSdk = zephyr."sdk-0_16".override {targets = ["arm-zephyr-eabi"];};
      zephyrPython = pkgs.python3.override {
        packageOverrides = _final: prev: {
          # Zephyr's Python environment includes this optional probe plugin;
          # relax its stale ~=0.14.0.post2 metadata constraint for hidapi 0.15.0.
          spsdk-mcu-link = prev.spsdk-mcu-link.overridePythonAttrs (_: {
            pythonRelaxDeps = ["hidapi"];
          });
        };
      };
      zephyrPythonEnv = zephyr.pythonEnv.override {
        python3 = zephyrPython;
        extraPackages = pythonPackages: [pythonPackages.protobuf];
      };
    in {
      default = pkgs.devshell.mkShell ({extraModulesPath, ...}: {
        imports = ["${extraModulesPath}/git/hooks.nix"];
        name = "zmk-config";
        devshell = {
          packages = with pkgs;
            [
              nixd
              cmake
              dtc
              gcc
              ninja
              protobuf
              yq # Make sure yq resolves to python-yq.
            ]
            ++ [
              treefmt.config.build.wrapper
              keymap-drawer
              zephyrPythonEnv
              zephyrSdk
            ];
        };
        env = [
          {
            name = "PYTHONPATH";
            value = "${zephyrPythonEnv}/${zephyrPythonEnv.sitePackages}";
          }
          {
            name = "ZMK_BUILD_DIR";
            value = "$PRJ_ROOT/.build";
          }
          {
            name = "ZMK_SRC_DIR";
            value = "$PRJ_ROOT/zmk/app";
          }
          {
            name = "ZEPHYR_SDK_INSTALL_DIR";
            value = "${zephyrSdk}";
          }
          {
            name = "ZEPHYR_TOOLCHAIN_VARIANT";
            value = "zephyr";
          }
        ];

        git.hooks = {
          enable = true;
          pre-commit.text = ''
            treefmt
            draw
          '';
        };

        commands = import ./nix/commands.nix {inherit lib pkgs;};
      });
    });
  };
}
