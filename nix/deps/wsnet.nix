{
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  boost188,
  c-ares,
  gtest,
  rapidjson,
  spdlog,
  skyr,
  wsOpenSSL,
  wsCurl,
}: let
  cmrc = fetchFromGitHub {
    owner = "vector-of-bool";
    repo = "cmrc";
    rev = "2.0.1";
    hash = "sha256-++16WAs2K9BKk8384yaSI/YD1CdtdyXVBIjGhqi4JIk=";
  };
  base64 = fetchFromGitHub {
    owner = "ReneNyffenegger";
    repo = "cpp-base64";
    rev = "V2.rc.08";
    hash = "sha256-6O0nmrC4pnzN4R3TOLCd+8cyje/n8mpCXX4lDYlXnHE=";
  };
  obfuscator = fetchFromGitHub {
    owner = "andrivet";
    repo = "ADVobfuscator";
    rev = "1852a0eb75b03ab3139af7f938dfb617c292c600";
    hash = "sha256-qleFYWPmCYHHtBO3Op3e8T6fxmC/3KwpatcQ8keiiz8=";
  };
in
  stdenv.mkDerivation {
    pname = "wsnet";
    version = "1.5.32";
    src = ../sources/wsnet;
    nativeBuildInputs = [cmake ninja pkg-config];
    buildInputs = [wsOpenSSL wsCurl boost188 c-ares gtest rapidjson spdlog skyr];
    preConfigure = ''
      mkdir -p nix-deps/cpp-base64
      cp ${base64}/base64.{cpp,h} nix-deps/cpp-base64/
      cp ${cmrc}/CMakeRC.cmake nix-deps/CMakeRCConfig.cmake
      cmakeFlagsArray+=(
        "-DCMakeRC_DIR=$PWD/nix-deps"
        "-DCPP_BASE64_INCLUDE_DIRS=$PWD/nix-deps"
      )
    '';
    cmakeFlags = [
      "-DIS_BUILD_TESTS=OFF"
      "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
      "-DCMAKE_POLICY_DEFAULT_CMP0167=NEW"
      "-DADVOBFUSCATOR_INCLUDE_DIRS=${obfuscator}"
    ];
    # Upstream does not provide desktop install rules or a CMake package.
    installPhase = ''
      runHook preInstall
      install -Dm755 libwsnet.so $out/lib/libwsnet.so
      cp -r ../include $out/include
      mkdir -p $out/lib/cmake/wsnet
      cat > $out/lib/cmake/wsnet/wsnetConfig.cmake <<EOF
      add_library(wsnet SHARED IMPORTED)
      set_target_properties(wsnet PROPERTIES
          IMPORTED_LOCATION "$out/lib/libwsnet.so"
          INTERFACE_INCLUDE_DIRECTORIES "$out/include")
      add_library(wsnet::wsnet ALIAS wsnet)
      EOF
      runHook postInstall
    '';
  }
