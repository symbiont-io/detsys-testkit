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
  conventional-changelog = pkgs.callPackage ./nix/conventional-changelog/default.nix {};
in

pkgs.mkShell {
  name = "dev-shell";

  buildInputs = [
    bazel_4
    buildifier # Bazel BUILD file formatter
    go
    clojure
    pythonEnv
    fake-lsb-release
    mypy
    haskell.compiler.ghc8103
    haskellPackages.cabal-install
    haskellPackages.tasty-discover
    haskellPackages.cabal-fmt # For formatting .cabal files, example
                              # invocation: `cabal-fmt -i ldfi.cabal`.
    haskellPackages.stylish-haskell # For import statement formatting, can be
                                    # invoked from spacemacs via `, F`.
    haskellPackages.ormolu # Haskell code formatting, to format all files in the
                           # current directory: `ormolu --mode inplace $(find . -name '*.hs')`.
    z3

    nixpkgs-fmt # Nix code formatting, example invocation: `nixpkgs-fmt default.nix`.
    conventional-changelog # Run `conventional-changelog -p angular` to generate changelog.
    git
    nix
    niv
    direnv
    lorri
    nix-index

    zlib.dev
    zlib.out
    pkgconfig # Use `pkg-config --libs zlib` from inside the shell to figure out
              # what to pass to GraalVM's native-image.
  ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.apple_sdk.frameworks.Foundation ];
}
