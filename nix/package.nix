{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  makeWrapper,
  coreutils,
  gnugrep,
  gnused,
  iproute2,
  kmod,
  procps,
  systemd,
  util-linux,
  e2fsprogs,
  openresolv,
  qt6,
  boost188,
  acl,
  c-ares,
  spdlog,
  miniaudio,
  nftables,
  src,
  wsnet,
  wsOpenSSL,
  wsOpenVPN,
  wsAmneziaWG,
  skyr,
}:
stdenv.mkDerivation {
  pname = "windscribe-desktop";
  version = "2.24.12";
  inherit src;
  nativeBuildInputs = [cmake ninja pkg-config makeWrapper qt6.wrapQtAppsHook];
  buildInputs = [
    wsOpenSSL
    wsnet
    qt6.qtbase
    qt6.qtsvg
    qt6.qttools
    qt6.qtwayland
    qt6.qtimageformats
    acl
    boost188
    c-ares
    spdlog
    miniaudio
    nftables
    skyr
  ];
  # WSTunnel and Control-D executables are not packaged yet.
  preConfigure = ''
    cmakeFlagsArray+=("-DCMAKE_INSTALL_RPATH=$out/lib" "-DWS_LINUX_INSTALL_DIR=$out/libexec/windscribe")
    mkdir -p build-libs/windscribe
  '';
  cmakeFlags = [
    "-DBUILD_INSTALLER=OFF"
    "-DBUILD_DEB=OFF"
    "-DBUILD_RPM=OFF"
    "-DUSE_SYSTEM_DEPENDENCIES=ON"
    "-DWS_OPENVPN_VERSION=${(lib.importJSON ./sources/registry/ports/openvpn/vcpkg.json).version}"
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DCMAKE_POLICY_DEFAULT_CMP0167=NEW"
    "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
    "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON"
    "-DOPENSSL_INCLUDE_DIR=${lib.getDev wsOpenSSL}/include"
    "-DOPENSSL_SSL_LIBRARY=${lib.getLib wsOpenSSL}/lib/libssl.so"
    "-DOPENSSL_CRYPTO_LIBRARY=${lib.getLib wsOpenSSL}/lib/libcrypto.so"
  ];
  env.NIX_CFLAGS_COMPILE = "-I${lib.getDev miniaudio}/include/miniaudio";
  # Upstream's install rules bundle vcpkg files; install our runtime layout directly.
  installPhase = ''
    runHook preInstall
    install -Dm755 src/client/Windscribe $out/bin/Windscribe
    install -Dm755 src/windscribe-cli/windscribe-cli $out/bin/windscribe-cli
    install -Dm755 src/helper/linux/helper $out/libexec/windscribe/helper
    install -Dm755 -t $out/libexec/windscribe/scripts \
      ../src/installer/windscribe/linux/opt/windscribe/scripts/*
    patchShebangs $out/libexec/windscribe/scripts
    # OpenVPN does not pass the helper's environment to its hooks.
    # Use shell wrappers so the Qt hook does not wrap these again as ELF executables.
    for script in $out/libexec/windscribe/scripts/*; do
      wrapProgramShell "$script" --set PATH "${lib.makeBinPath [coreutils gnugrep gnused iproute2 kmod procps systemd util-linux e2fsprogs openresolv]}"
    done
    mkdir -p $out/lib
    ln -s ${wsnet}/lib/libwsnet.so $out/lib/libwsnet.so
    runHook postInstall
  '';
  # Add this after the Qt hook so it stays a plain symlink, not a Qt-wrapped executable.
  postFixup = ''
    ln -s ${wsOpenVPN}/sbin/openvpn $out/libexec/windscribe/windscribeopenvpn
    ln -s ${wsAmneziaWG}/bin/amneziawg-go $out/libexec/windscribe/windscribeamneziawg
  '';
  meta.platforms = ["x86_64-linux"];
}
