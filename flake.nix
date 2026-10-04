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
      zephyrPythonEnv = zephyr.pythonEnv.override {
        extraPackages = pythonPackages: [pythonPackages.protobuf];
      };
      checkYq = ''
        if yq --help 2>&1 | grep -qi 'eval'; then
          echo "This command requires python-yq, but PATH contains golang-yq" >&2
          exit 1
        fi
      '';
      parseTargets = ''
        parse_targets() {
          local expr="$1"
          local pattern="$expr"
          local filter='
            def normalize:
              if . == null then ""
              elif type == "array" then join(" ")
              else tostring
              end;
            def row: map(normalize) | join(",");
            (
              ([.board, .shield, .snippet, ."artifact-name", ."cmake-args"]
                | map(if . == null then [null] elif type == "array" then . else [.] end)
                | combinations),
              ((.include // [])[]
                | [.board, .shield, .snippet, ."artifact-name", ."cmake-args"])
            ) | row
          '

          [[ "$expr" == all ]] && pattern='.*'
          yq -r "$filter" "$PRJ_ROOT/build.yaml" | grep -v '^,' | grep -i "$pattern" || true
        }
      '';
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

        commands = [
          {
            name = "check";
            command = "nix flake check \"$PRJ_ROOT\"";
            help = "runs test suite and formatter";
          }
          {
            name = "clean";
            command = "rm -rf \"$PRJ_ROOT/.build\" \"$PRJ_ROOT/firmware\"";
            help = "removes .build and firmware directories";
          }
          {
            name = "build";
            category = "[dev]";
            command = ''
              cd "$PRJ_ROOT"
              ${checkYq}
              ${parseTargets}

              expr="''${1:-all}"
              if (($#)); then
                shift
              fi

              targets="$(parse_targets "$expr")"
              if [[ -z "$targets" ]]; then
                echo "No matching targets found. Aborting..." >&2
                exit 1
              fi

              while IFS=, read -r board shield snippet artifact cmake_args; do
                if [[ -z "$artifact" ]]; then
                  if [[ -n "$shield" ]]; then
                    artifact="''${shield// /+}-''${board//\//_}"
                  else
                    artifact="''${board//\//_}"
                  fi
                fi
                build_dir="$PRJ_ROOT/.build/$artifact"

                echo "Building firmware for $artifact..."
                build_command=(west build -s "$PRJ_ROOT/zmk/app" -d "$build_dir" -b "$board")
                build_command+=("$@")
                [[ -n "$snippet" ]] && build_command+=(-S "$snippet")
                build_command+=(-- "-DZMK_CONFIG=$PRJ_ROOT/config")
                [[ -n "$shield" ]] && build_command+=("-DSHIELD=$shield")
                if [[ -n "$cmake_args" ]]; then
                  read -r -a extra_cmake_args <<<"$cmake_args"
                  build_command+=("''${extra_cmake_args[@]}")
                fi
                "''${build_command[@]}"

                mkdir -p "$PRJ_ROOT/firmware"
                if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
                  cp "$build_dir/zephyr/zmk.uf2" "$PRJ_ROOT/firmware/$artifact.uf2"
                else
                  cp "$build_dir/zephyr/zmk.bin" "$PRJ_ROOT/firmware/$artifact.bin"
                fi
              done <<<"$targets"
            '';
            help = "build all keyboards by default or select keyboard name";
          }
          {
            name = "list";
            category = "[dev]";
            command = ''
              cd "$PRJ_ROOT"
              ${checkYq}
              ${parseTargets}

              parse_targets all \
                | sed 's|[@/][^,]*,|,|' \
                | sed 's|\([^,]*\),\([^,]\+\),.*|\2|' \
                | sed 's|\([^,]*\),,.*|\1|' \
                | sort
            '';
            help = "lists available build targets";
          }
          {
            name = "flash";
            category = "[dev]";
            command = ''
              cd "$PRJ_ROOT"
              ${checkYq}
              ${parseTargets}

              expr="''${1:-all}"
              build "$@"
              targets="$(parse_targets "$expr")"

              while IFS=, read -r board shield _snippet artifact _cmake_args; do
                if [[ -z "$artifact" ]]; then
                  if [[ -n "$shield" ]]; then
                    artifact="''${shield// /+}-''${board//\//_}"
                  else
                    artifact="''${board//\//_}"
                  fi
                fi

                echo "Flashing firmware for $artifact..."
                west flash -d "$PRJ_ROOT/.build/$artifact"
              done <<<"$targets"
            '';
            help = "builds and flashes a matching target";
          }
          {
            name = "draw";
            category = "[dev]";
            command = ''
              cd "$PRJ_ROOT"
              ${checkYq}

              keymap -c "$PRJ_ROOT/draw/config.yaml" parse \
                -z "$PRJ_ROOT/config/base.keymap" \
                --virtual-layers Combos >"$PRJ_ROOT/draw/base.yaml"
              yq -Yi '.combos.[].l = ["Combos"]' "$PRJ_ROOT/draw/base.yaml"
              keymap -c "$PRJ_ROOT/draw/config.yaml" draw \
                "$PRJ_ROOT/draw/base.yaml" -k ferris/sweep >"$PRJ_ROOT/draw/base.svg"

              jq_expr='
                def extract_label: if type == "string" then . else .t end;
                def is_transparent: type == "object" and (.type == "trans" or .type == "held");
                .layers = {
                  Base: [
                    [.layers.Base, .layers.Nav, .layers.Fn, .layers.Num, .layers.Sys] | transpose[] |
                    (.[0] | if type == "string" then {t: .} else . end) as $base |
                    (.[1] | if is_transparent then null else extract_label end) as $nav |
                    (.[2] | if is_transparent then null else extract_label end) as $fn |
                    (.[3] | if is_transparent then null else extract_label end) as $num |
                    (.[4] | if is_transparent then null else extract_label end) as $sys |
                    $base
                    + (if $nav == null then {} else {tr: $nav} end)
                    + (if $fn == null then {} else {tl: $fn} end)
                    + (if $num == null then {} else {bl: $num} end)
                    + (if $sys == null then {} else {br: $sys} end)
                  ],
                  Combos: .layers.Combos
                } |
                .combos = [.combos[] | .l = ["Combos"]]
              '
              yq -y "$jq_expr" "$PRJ_ROOT/draw/base.yaml" >"$PRJ_ROOT/draw/overview.yaml"
              keymap -c "$PRJ_ROOT/draw/config.yaml" draw \
                "$PRJ_ROOT/draw/overview.yaml" -k ferris/sweep >"$PRJ_ROOT/draw/overview.svg"
              sed -i '/<text.*class="label"/d' "$PRJ_ROOT/draw/overview.svg"
            '';
            help = "regenerates the keymap diagrams";
          }
          {
            name = "snapshot-test";
            category = "[dev]";
            command = ''
              if (($# == 0)); then
                echo "usage: snapshot-test <test-path> [--no-build] [--verbose] [--auto-accept]" >&2
                exit 2
              fi

              testpath="$1"
              shift
              testcase="$(basename "$testpath")"
              build_dir="$PRJ_ROOT/.build/tests/$testcase"
              config_dir="$(realpath "$testpath")"
              flags="$*"

              if [[ "$flags" != *--no-build* ]]; then
                echo "Running $testcase..."
                rm -rf "$build_dir"
                west build -s "$PRJ_ROOT/zmk/app" -d "$build_dir" \
                  -b native_sim//zmk_test_mock -- \
                  -DCONFIG_ASSERT=y -DZMK_CONFIG="$config_dir"
              fi

              "$build_dir/zephyr/zmk.exe" \
                | sed -e 's/.*> //' \
                | tee "$build_dir/keycode_events.full.log" \
                | sed -n -f "$config_dir/events.patterns" >"$build_dir/keycode_events.log"

              if [[ "$flags" == *--verbose* ]]; then
                cat "$build_dir/keycode_events.log"
              fi
              if [[ "$flags" == *--auto-accept* ]]; then
                cp "$build_dir/keycode_events.log" "$config_dir/keycode_events.snapshot"
              fi
              diff -auZ "$config_dir/keycode_events.snapshot" "$build_dir/keycode_events.log"
            '';
            help = "runs a ZMK module snapshot test";
          }
          {
            name = "pin";
            category = "[west]";
            help = "modifies pins then runs init";
            command = ''
              ${lib.getExe pkgs.pin-west} pin && init
            '';
          }
          {
            name = "init";
            category = "[west]";
            command = ''
              cd "$PRJ_ROOT"
              if [[ ! -d "$PRJ_ROOT/.west" ]]; then
                west init -l config
              fi

              GIT_CONFIG_COUNT=2 \
                GIT_CONFIG_KEY_0=pack.threads \
                GIT_CONFIG_VALUE_0=1 \
                GIT_CONFIG_KEY_1=core.deltaBaseCacheLimit \
                GIT_CONFIG_VALUE_1=64m \
                west update --narrow --fetch-opt=--filter=blob:none
              west zephyr-export
            '';
            help = "initializes or synchronizes the West workspace";
          }
          {
            name = "bump";
            category = "[west]";
            command = "cd \"$PRJ_ROOT\" && ${lib.getExe pkgs.pin-west} bump && init";
            help = "updates and pins the West manifest";
          }
        ];
      });
    });
  };
}
