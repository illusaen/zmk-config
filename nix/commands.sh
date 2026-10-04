#!/usr/bin/env bash

check_yq() {
  if yq --help 2>&1 | grep -qi 'eval'; then
    echo "This command requires python-yq, but PATH contains golang-yq" >&2
    exit 1
  fi
}

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

target_artifact() {
  local board="$1"
  local shield="$2"
  local artifact="$3"

  if [[ -n "$artifact" ]]; then
    printf '%s' "$artifact"
  elif [[ -n "$shield" ]]; then
    printf '%s-%s' "${shield// /+}" "${board//\//_}"
  else
    printf '%s' "${board//\//_}"
  fi
}

pin_west() {
  "${PIN_WEST:-pin-west}" "$@"
}

cmd_check() {
  nix flake check "$PRJ_ROOT"
}

cmd_clean() {
  rm -rf "$PRJ_ROOT/.build" "$PRJ_ROOT/firmware"
}

cmd_build() {
  local expr targets board shield snippet artifact cmake_args build_dir
  local -a build_command extra_cmake_args

  cd "$PRJ_ROOT"
  check_yq
  expr="${1:-all}"
  if (($#)); then
    shift
  fi

  targets="$(parse_targets "$expr")"
  if [[ -z "$targets" ]]; then
    echo "No matching targets found. Aborting..." >&2
    exit 1
  fi

  while IFS=, read -r board shield snippet artifact cmake_args; do
    artifact="$(target_artifact "$board" "$shield" "$artifact")"
    build_dir="$PRJ_ROOT/.build/$artifact"

    echo "Building firmware for $artifact..."
    build_command=(west build -s "$PRJ_ROOT/zmk/app" -d "$build_dir" -b "$board")
    build_command+=("$@")
    [[ -n "$snippet" ]] && build_command+=(-S "$snippet")
    build_command+=(-- "-DZMK_CONFIG=$PRJ_ROOT/config")
    [[ -n "$shield" ]] && build_command+=("-DSHIELD=$shield")
    if [[ -n "$cmake_args" ]]; then
      read -r -a extra_cmake_args <<<"$cmake_args"
      build_command+=("${extra_cmake_args[@]}")
    fi
    "${build_command[@]}"

    mkdir -p "$PRJ_ROOT/firmware"
    if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
      cp "$build_dir/zephyr/zmk.uf2" "$PRJ_ROOT/firmware/$artifact.uf2"
    else
      cp "$build_dir/zephyr/zmk.bin" "$PRJ_ROOT/firmware/$artifact.bin"
    fi
  done <<<"$targets"
}

cmd_list() {
  cd "$PRJ_ROOT"
  check_yq
  parse_targets all \
    | sed 's|[@/][^,]*,|,|' \
    | sed 's|\([^,]*\),\([^,]\+\),.*|\2|' \
    | sed 's|\([^,]*\),,.*|\1|' \
    | sort
}

cmd_flash() {
  local expr targets board shield artifact

  cd "$PRJ_ROOT"
  check_yq
  expr="${1:-all}"
  cmd_build "$@"
  targets="$(parse_targets "$expr")"

  while IFS=, read -r board shield _snippet artifact _cmake_args; do
    artifact="$(target_artifact "$board" "$shield" "$artifact")"

    echo "Flashing firmware for $artifact..."
    west flash -d "$PRJ_ROOT/.build/$artifact"
  done <<<"$targets"
}

cmd_draw() {
  local jq_expr

  cd "$PRJ_ROOT"
  check_yq

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
}

cmd_pin() {
  pin_west pin && cmd_init
}

cmd_init() {
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
}

cmd_bump() {
  cd "$PRJ_ROOT" && pin_west bump && cmd_init
}

if (($# == 0)); then
  echo "usage: commands.sh <command> [args...]" >&2
  exit 2
fi

command_name="${1//-/_}"
shift
handler="cmd_$command_name"

if ! declare -F "$handler" >/dev/null; then
  echo "unknown command: $command_name" >&2
  exit 2
fi

"$handler" "$@"
