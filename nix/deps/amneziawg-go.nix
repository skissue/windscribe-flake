{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "amneziawg-go";
  version = "0.2.16";

  src = fetchFromGitHub {
    owner = "amnezia-vpn";
    repo = "amneziawg-go";
    rev = "730d6c39d0c4e348a3d080bebe496664215e5c99";
    hash = "sha256-JGmWMPVgereSZmdHUHC7ZqWCwUNfxfj3xBf/XDDHhpo=";
  };

  # Upstream's Makefile generates this from `git describe`; fetchFromGitHub omits .git.
  postPatch = ''
    substituteInPlace version.go \
      --replace-fail 'const Version = "0.0.20250522"' 'const Version = "v${version}"'
  '';

  vendorHash = "sha256-ZO8sLOaEY3bii9RSxzXDTCcwlsQEYmZDI+X1WPXbE9c=";
  subPackages = ["."];
  # Nix's vendoring exposes dependency sources to this repository-wide formatting test.
  checkFlags = ["-skip=TestFormatting"];

  meta.platforms = lib.platforms.linux;
}
