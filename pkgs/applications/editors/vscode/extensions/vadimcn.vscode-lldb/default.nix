{ pkgs, lib, stdenv, fetchFromGitHub, runCommand, rustPlatform, makeWrapper, llvmPackages
, buildNpmPackage, cmake, nodejs, unzip, python3, pkg-config, libsecret, darwin
}:
assert lib.versionAtLeast python3.version "3.5";
let
  publisher = "vadimcn";
  pname = "vscode-lldb";
  version = "1.9.1";

  vscodeExtUniqueId = "${publisher}.${pname}";
  vscodeExtPublisher = publisher;
  vscodeExtName = pname;

  src = fetchFromGitHub {
    owner = "vadimcn";
    repo = "vscode-lldb";
    rev = "v${version}";
    sha256 = "sha256-DqxdZtSW8TZaOFGXOZQ7a4tmgRj6iAWDppCNomdfVxY=";
  };

  # need to build a custom version of lldb and llvm for enhanced rust support
  lldb = (import ./lldb.nix { inherit fetchFromGitHub runCommand llvmPackages; });

  adapter = rustPlatform.buildRustPackage {
    pname = "${pname}-adapter";
    inherit version src;

    cargoSha256 = "sha256-+hfNkr9cZbOcWdWKUWUqDj9a0PKjKeApFXYZzS1XokE=";

    nativeBuildInputs = [ makeWrapper ];

    buildAndTestSubdir = "adapter";

    buildFeatures = [ "weak-linkage" ];

    cargoBuildFlags = [
      "--lib"
      "--bin=codelldb"
    ];

    # Tests are linked to liblldb but it is not available here.
    doCheck = false;
  };

  nodeDeps = buildNpmPackage {
    pname = "${pname}-node-deps";
    inherit version src;

    npmDepsHash = "sha256-Cdlq1jxHSCfPjXhasClc6XzEUp3vlLgkStbhYtCyc7E=";

    nativeBuildInputs = [
      python3
      pkg-config
    ];

    buildInputs = [
      libsecret
    ] ++ lib.optionals stdenv.isDarwin (with darwin.apple_sdk.frameworks; [
      Security
      AppKit
    ]);

    dontNpmBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      cp -r node_modules $out/lib

      runHook postInstall
    '';
  };

in stdenv.mkDerivation {
  pname = "vscode-extension-${publisher}-${pname}";
  inherit src version vscodeExtUniqueId vscodeExtPublisher vscodeExtName;

  installPrefix = "share/vscode/extensions/${vscodeExtUniqueId}";

  nativeBuildInputs = [ cmake nodejs unzip makeWrapper ];

  patches = [ ./cmake-build-extension-only.patch ];

  postPatch = ''
    # temporary patch for forgotten version updates
    substituteInPlace CMakeLists.txt \
      --replace "1.9.0" ${version}
  '';

  postConfigure = ''
    cp -r ${nodeDeps}/lib/node_modules .
  '';

  cmakeFlags = [
    # Do not append timestamp to version.
    "-DVERSION_SUFFIX="
  ];
  makeFlags = [ "vsix_bootstrap" ];

  preBuild = lib.optionalString stdenv.isDarwin ''
    export HOME=$TMPDIR
  '';

  installPhase = ''
    ext=$out/$installPrefix
    runHook preInstall

    unzip ./codelldb-bootstrap.vsix 'extension/*' -d ./vsix-extracted

    mkdir -p $ext/{adapter,formatters}
    mv -t $ext vsix-extracted/extension/*
    cp -t $ext/adapter ${adapter}/{bin,lib}/* ../adapter/*.py
    wrapProgram $ext/adapter/codelldb \
      --set-default LLDB_DEBUGSERVER_PATH "${lldb.out}/bin/lldb-server"
    cp -t $ext/formatters ../formatters/*.py
    ln -s ${lldb.lib} $ext/lldb
    # Mark that all components are installed.
    touch $ext/platform.ok

    runHook postInstall
  '';

  # `adapter` will find python binary and libraries at runtime.
  postFixup = ''
    wrapProgram $out/$installPrefix/adapter/codelldb \
      --prefix PATH : "${python3}/bin" \
      --prefix LD_LIBRARY_PATH : "${python3}/lib"
  '';

  passthru = {
    inherit lldb adapter;
    updateScript = ./update.sh;
  };

  meta = {
    description = "A native debugger extension for VSCode based on LLDB";
    homepage = "https://github.com/vadimcn/vscode-lldb";
    license = [ lib.licenses.mit ];
    maintainers = [ lib.maintainers.nigelgbanks ];
    platforms = lib.platforms.all;
  };
}
