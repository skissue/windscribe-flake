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
    rev = "85f07f7b784009adf90129b3854c5b742ca3cef9";
    hash = "sha256-yFnNtMf8uEtKYEDxIBzhmqYXX7phEM/MYwXrI3WNvP8=";
  };
  # The registry's other patches concern CMake installation and Windows support.
  patches = [
    ../sources/registry/ports/openvpn/anti-censorship.patch
    ../sources/registry/ports/openvpn/0002-Anti-censorship-add-support-for-Amnezia-s-Jc-Jmin-Jm.patch
    ../sources/registry/ports/openvpn/0003-Anti-censorship-introduce-junk-first-option-Jc-befor.patch
    ../sources/registry/ports/openvpn/ws-directive-policy.patch
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
    "--disable-plugins"
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
