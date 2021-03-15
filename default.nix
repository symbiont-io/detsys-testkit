{ sources ? import ./nix/sources.nix
, pkgs ? import sources.nixpkgs {} }:
with pkgs;

stdenv.mkDerivation {
  pname = "detsys";
  version = "latest";

  src = ./bazel-bin/src;

  phases = [ "installPhase" "installCheckPhase" ];

  propagatedBuildInputs = [ z3 ];

  installPhase = ''
    install -D $src/cli/cli_/cli \
               $out/bin/detsys
    install -D $src/db/db_/db \
               $out/bin/detsys-db
    install -D $src/debugger/cmd/detsys-debug/detsys-debug_/detsys-debug \
               $out/bin/detsys-debug
    install -D $src/scheduler/scheduler-bin \
               $out/bin/detsys-scheduler
    install -D $src/checker/checker-bin \
               $out/bin/detsys-checker
    install -D $src/ldfi2/ldfi2 \
               $out/bin/detsys-ldfi
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    # TODO(stevan): figure out why this doesn't work.
    #if [ "$($out/bin/detsys --version)" != "detsys version unknown" ]; then
    #   echo "version mismatch"
    #fi
  '';
}
