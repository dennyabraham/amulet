{ pkgs ? import <nixpkgs> { } }:
let
  fakeGitVersion = version:
    pkgs.writeShellScriptBin "git"
    "mkdir -p .git/logs ; touch .git/logs/HEAD ; echo ${version}"; # a fake git script so that when something tries to ask for the version, it doesn't fail
  haskellPkgs = pkgs.haskell.packages.ghc8107;
  callHackage = haskellPkgs.callHackage;
  amuletGitSrc = builtins.fetchGit {
    url = "https://github.com/amuletml/amulet";
    ref = "master";
  };
  amuletSrc = ./.;
  printSrc =
    pkgs.runCommand "amuletSrc" { } "echo ${amuletSrc} ; ls ${amuletSrc}";
  amulet = pkgs.haskell.lib.dontHaddock
    ((haskellPkgs.callCabal2nix "amuletml" (amuletSrc) {
      hslua = callHackage "hslua" "1.3.0.1" { };
    }).overrideAttrs ({ buildInputs ? [ ], checkInputs ? [ ], ... }: {
      buildInputs = [
        pkgs.llvmPackages_12.lld
        (fakeGitVersion "master")
        pkgs.lua5_3
        pkgs.gmp5
        pkgs.libffi
        pkgs.autoPatchelfHook
        # pkgs.breakpointHook
      ] ++ buildInputs;
      # postBuild =
      #   "echo 'in pre patch' ; pwd ; ls dist/build ; rm -rf dist/build/libHS*";
      postInstall = ''
        rm -rf $out/lib/*
        pwd
        ls
        cp -r lib/ $out/
      '';
      doCheck = true;
      checkInputs = [ pkgs.gmp5 ] ++ checkInputs;
    }));
in amulet
