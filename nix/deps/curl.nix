{
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  wsOpenSSL,
  zlib,
  c-ares,
}:
stdenv.mkDerivation {
  pname = "windscribe-curl";
  version = "8.21.0";
  src = fetchFromGitHub {
    owner = "curl";
    repo = "curl";
    rev = "curl-8_21_0";
    hash = "sha256-7UGy24Q0Ny+U9hWXV6BzgKc45zkvw+I24GvgyaYsy/I=";
  };
  patches = [
    ../sources/registry/ports/curl/super-large-padding-extension.patch
    ../sources/registry/ports/curl/Export-SSL_OP_LEGACY_EC_POINT_FORMATS-OpenSSL-option.patch
  ];
  nativeBuildInputs = [cmake ninja pkg-config];
  # CURLConfig.cmake discovers these dependencies in consumers as well.
  propagatedBuildInputs = [wsOpenSSL zlib c-ares];
  cmakeFlags = [
    "-DBUILD_TESTING=OFF"
    "-DBUILD_CURL_EXE=OFF"
    "-DBUILD_SHARED_LIBS=ON"
    "-DCURL_USE_OPENSSL=ON"
    "-DUSE_ECH=ON"
    "-DENABLE_ARES=ON"
    "-DCURL_USE_LIBPSL=OFF"
    "-DCURL_USE_LIBSSH2=OFF"
    # Match nixpkgs' curl ABI for Qt's transitive libproxy dependency.
    "-DCURL_LIBCURL_VERSIONED_SYMBOLS=ON"
  ];
}
