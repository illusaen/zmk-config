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
    pin-west.url = "github:urob/pin-west";
    pin-west.flake = false;
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
        overlays = [devshell.overlays.default (final: _prev: {pin-west = final.python3Packages.callPackage "${pin-west}/package.nix" {};})];
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
          options = ["--fix"];
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
    }: {
      default = pkgs.devshell.mkShell ({extraModulesPath, ...}: {
        imports = ["${extraModulesPath}/git/hooks.nix"];
        name = "zmk-config";
        devshell = {
          startup = {
            initOrSyncWest.text = ''
              if [ -d ".west" ]; then
                west update --fetch-opt=--filter=blob:none
              else
                west init -l config
                west update --fetch-opt=--filter=blob:none
                west zephyr-export
              fi
            '';
          };
          #           startup.setupLibatomic.text = lib.optionalString (pkgs.stdenv.hostPlatform.isLinux) (let libatomic = pkgs.runCommand "libatomic" {} ''
          #               mkdir -p $out/lib
          #               cp -d ${pkgs.stdenv.cc.cc.lib}/lib/libatomic.so* $out/lib/
          #             ''; in ''
          # export LD_LIBRARY_PATH="${libatomic}/lib
          #           '');
          packages = with pkgs;
            [
              nixd
              cmake
              dtc
              gcc
              ninja
              yq # Make sure yq resolves to python-yq.
              # -- Used by just_recipes and west_commands. Most systems already have them. --
              # pkgs.gawk
              # pkgs.unixtools.column
              # pkgs.coreutils # cp, cut, echo, mkdir, sort, tail, tee, uniq, wc
              # pkgs.diffutils
              # pkgs.findutils # find, xargs
              # pkgs.gnugrep
              # pkgs.gnused
            ]
            ++ [
              treefmt.config.build.wrapper
              keymap-drawer
              pin-west
              zephyr.pythonEnv
              (zephyr.sdk.override {targets = ["arm-zephyr-eabi"];})
            ];
        };
        env = [
          {
            name = "PYTHONPATH";
            value = "${zephyr.pythonEnv}/${zephyr.pythonEnv.sitePackages}";
          }
          {
            name = "ZMK_BUILD_DIR";
            value = "$PRJ_ROOT/.build";
          }
          {
            name = "ZMK_SRC_DIR";
            value = "$PRJ_ROOT/zmk/app";
          }
        ];

        git.hooks = {
          enable = true;
          pre-commit.text = ''
            treefmt
          '';
        };

        commands = [
          {
            name = "check";
            command = "nix flake check";
            help = "runs test suite and formatter";
          }
          {
            name = "clean";
            command = "rm -rf .build firmware";
            help = "removes .build and firmware directories";
          }
          {
            name = "bump-west";
            command = "pin-west bump && west update --fetch-opt=--filter=blob:none";
            help = "removes .build and firmware directories";
          }
        ];
      });
    });
  };
}
