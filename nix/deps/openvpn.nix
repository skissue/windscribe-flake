{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  wsOpenSSL,
  lzo,
  lz4,
  libnl,
  libcap_ng,
  cmocka,
  coreutils,
}:
stdenv.mkDerivation {
  pname = "windscribe-openvpn";
  version = (lib.importJSON ../sources/registry/ports/openvpn/vcpkg.json).version;
  src = fetchFromGitHub {
    owner = "OpenVPN";
    repo = "openvpn";
    rev = "b25bb2a8bda814edab39b4246d4e296330a7a29e";
    hash = "sha256-oyKidDw+3PRmHezyftfYXqe8pIwF0Bnr4ue1Alq5zKc=";
  };
  # The registry's other patches concern CMake installation and Windows applink.
  patches = [
    ../sources/registry/ports/openvpn/anti-censorship.patch
    ./openvpn-tests.patch
  ];
  postPatch = ''
    substituteInPlace tests/unit_tests/openvpn/test_tls_crypt.c \
      --replace-fail '"/usr/bin/true"' '"${coreutils}/bin/true"' \
      --replace-fail '"/usr/bin/false"' '"${coreutils}/bin/false"'
  '';
  nativeBuildInputs = [autoreconfHook pkg-config];
  buildInputs = [wsOpenSSL lzo lz4 libnl libcap_ng cmocka];
  configureFlags = [
    "--with-crypto-library=openssl"
    "--disable-plugin-auth-pam"
    "--disable-plugin-down-root"
  ];
  enableParallelBuilding = true;
  doCheck = true;
  # Unit tests only: the top-level check target also starts networking tests.
  checkPhase = ''
    runHook preCheck
    make -C tests/unit_tests check || {
      find tests/unit_tests -name test-suite.log -exec cat {} \;
      exit 1
    }
    runHook postCheck
  '';
  installTargets = ["install-exec"];
  meta.platforms = ["x86_64-linux"];
}
