# This file has been generated by node2nix 1.5.2. Do not edit!

{pkgs ? import <nixpkgs> {
    inherit system;
  }, system ? builtins.currentSystem, nodejs ? pkgs."nodejs-8_x"}:

let
  nodeEnv = import <nixpkgs/pkgs/development/node-packages/node-env.nix> {
    inherit (pkgs) stdenv python2 utillinux runCommand writeTextFile;
    inherit nodejs;
  };
in
import ./node-packages.nix {
  inherit (pkgs) fetchurl fetchzip fetchgit;
  inherit nodeEnv;
}