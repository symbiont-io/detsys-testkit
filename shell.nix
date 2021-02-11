{ sources ? import ./nix/sources.nix
, pkgs ? import sources.nixpkgs {} }:
with pkgs;

let
  pythonEnv = python38.withPackages (ps: [ ps.pip ]);
  fake-lsb-release = pkgs.writeScriptBin "lsb_release" ''
    #!${pkgs.runtimeShell}

    case "$1" in
      -i) echo "nixos";;
      -r) echo "nixos";;
    esac
  '';
in

pkgs.mkShell {
  name = "dev-shell";

  buildInputs = [
    bazel_3
    buildifier # Bazel BUILD file formatter
    go
    clojure
    pythonEnv
    fake-lsb-release
    mypy
    haskellPackages.ghc
    haskellPackages.cabal-install
    haskellPackages.tasty-discover
    haskellPackages.cabal-fmt       # For formatting .cabal files, example
                                    # invocation: `cabal-fmt -i ldfi.cabal`.
    haskellPackages.stylish-haskell # For import statement formatting, can be
                                    # invoked from spacemacs via `, F`.
    z3

    git
    nix
    niv
    direnv
    lorri
    nix-index
  ];
}
