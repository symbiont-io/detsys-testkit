{ sources ? import ./../../nix/sources.nix
, pkgs ? import sources.nixpkgs {}
}:
with pkgs;

let
  mvn2nix = import (fetchTarball https://github.com/fzakaria/mvn2nix/archive/master.tar.gz) {};
  mavenRepository =
    mvn2nix.buildMavenRepositoryFromLockFile { file = ./mvn2nix-lock.json; };
  inherit (import sources.gitignore {}) gitignoreSource;
in stdenv.mkDerivation rec {
  pname = "checker";
  version = "latest";
  name = "${pname}-${version}";
  src = gitignoreSource ./.;

  buildInputs = [ clojure jdk11_headless graalvm11-ce ]
                ++ lib.optional stdenv.isLinux [ freetype.dev ];

  buildPhase = ''
    # This is a dummy git hash to avoid breaking the nix cache, it will be
    # patched in the `postInstall` phase of the top-level `default.nix`.
    export DETSYS_CHECKER_VERSION="0000000000000000000000000000000000000000-nix"
    export CLASSPATH=$(find ${mavenRepository} -name "*.jar" -printf ':%h/%f')
    export builddir=$TMP/classes
    mkdir -p $builddir

    echo "compiling lock fix workaround"
    javac java/src/lockfix/LockFix.java -cp $CLASSPATH -d $builddir

    echo "compiling clojure sources"
    # `clj` tries to create some folder in the home directory...
    export HOME=$TMP/home
    mkdir -p $HOME
    clj -Scp src:$CLASSPATH:$builddir \
      -J-Djava.awt.headless=true \
      -J-Dclojure.compile.path=$builddir \
      -M -e "(compile (quote ${pname}.core))"

    echo "creating manifest file"
    echo "Main-Class: ${pname}.core" > manifest.txt
    echo "Class-Path: . resources/" >> manifest.txt
    find ${mavenRepository} -name '*.jar' -printf '  %h/%f\n' >> manifest.txt
    cat manifest.txt

    echo "creating fat/uber jar"
    jar cvfm ${name}.jar manifest.txt -C $builddir .

    echo "compiling native image"
    native-image \
      -jar ${name}.jar \
      -H:Name=${pname} \
      ${lib.optionalString stdenv.isDarwin ''-H:-CheckToolchain''} \
      -H:+ReportExceptionStackTraces \
      -H:IncludeResources="db/.*|static/.*|templates/.*|.*.yml|.*.xml|.*/org/sqlite/.*|org/sqlite/.*" \
      -H:JNIConfigurationFiles=${src}/native-image/jni-config.json \
      -H:ReflectionConfigurationFiles=${src}/native-image/reflection-config.json \
      -J-Dclojure.spec.skip-macros=true \
      -J-Dclojure.compiler.direct-linking=true \
      -J-Dfile.encoding=UTF-8 \
      -J-Djava.awt.headless=true \
      -J-Dclojure.tools.logging.factory=clojure.tools.logging.impl/slf4j-factory \
      --initialize-at-build-time \
      --initialize-at-build-time=org.sqlite.JDBC \
      --initialize-at-build-time=org.sqlite.core.DB$ProgressObserver \
      --initialize-at-build-time=org.sqlite.core.DB \
      --initialize-at-build-time=org.sqlite.core.NativeDB \
      --initialize-at-build-time=org.sqlite.ProgressHandler \
      --initialize-at-build-time=org.sqlite.Function \
      --initialize-at-build-time=org.sqlite.Function$Aggregate \
      --initialize-at-build-time=org.sqlite.Function$Window \
      --initialize-at-run-time=sun.font.SunFontManager \
      --initialize-at-run-time=sun.font.StrikeCache \
      --initialize-at-run-time=sun.font.SunLayoutEngine \
      --initialize-at-run-time=sun.font.FontManagerNativeLibrary \
      --initialize-at-run-time=javax.imageio.ImageTypeSpecifier \
      --initialize-at-run-time=sun.java2d.SurfaceData \
      --initialize-at-run-time='com.sun.imageio.plugins.jpeg.JPEG$JCS' \
      --initialize-at-run-time='sun.awt.dnd.SunDropTargetContextPeer$EventDispatcher' \
      ${lib.optionalString stdenv.isLinux ''
      --initialize-at-run-time=sun.awt.X11GraphicsConfig \
      --initialize-at-run-time=sun.awt.X11.MotifDnDConstants \
      --initialize-at-run-time=sun.java2d.xr.XRBackendNative \
      --initialize-at-run-time=sun.awt.X11.XWM \
      --initialize-at-run-time=sun.awt.X11.XSelection \
      --initialize-at-run-time=sun.awt.X11.XDnDConstants \
      --initialize-at-run-time=sun.awt.X11.WindowPropertyGetter \
      --initialize-at-run-time=sun.awt.X11InputMethodBase \
      --initialize-at-run-time=sun.awt.X11.XWindow \
      ''} \
      --report-unsupported-elements-at-runtime \
      --allow-incomplete-classpath \
      --verbose \
      --no-fallback \
      --no-server
  '';

  installPhase = ''
    mkdir -p $out/bin
    install -Dm755 ${pname} $out/bin/detsys-${pname}
  '';
}
