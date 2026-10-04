{
  lib,
  pkgs,
}: let
  script = ./commands.sh;
  run = command: "PIN_WEST=${lib.getExe pkgs.pin-west} bash ${script} ${command} \"$@\"";
in [
  {
    name = "check";
    command = run "check";
    help = "runs test suite and formatter";
  }
  {
    name = "clean";
    command = run "clean";
    help = "removes .build and firmware directories";
  }
  {
    name = "build";
    category = "[dev]";
    command = run "build";
    help = "build all keyboards by default or select keyboard name";
  }
  {
    name = "list";
    category = "[dev]";
    command = run "list";
    help = "lists available build targets";
  }
  {
    name = "flash";
    category = "[dev]";
    command = run "flash";
    help = "builds and flashes a matching target";
  }
  {
    name = "draw";
    category = "[dev]";
    command = run "draw";
    help = "regenerates the keymap diagrams";
  }
  {
    name = "pin";
    category = "[west]";
    command = run "pin";
    help = "modifies pins then runs init";
  }
  {
    name = "init";
    category = "[west]";
    command = run "init";
    help = "initializes or synchronizes the West workspace";
  }
  {
    name = "bump";
    category = "[west]";
    command = run "bump";
    help = "updates and pins the West manifest";
  }
]
