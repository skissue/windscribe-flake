{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "amneziawg-go";
  version = "3.1.20260828";

  src = fetchFromGitHub {
    owner = "amnezia-vpn";
    repo = "amneziawg-go";
    rev = "b5928efb6ca19f0153958460c3d141f04abc5c2e";
    hash = "sha256-vZb72SA+6v8FXZX247K05yiVEBWpLqAAIyw6bEE4eUQ=";
  };

  # Upstream's Makefile generates this from `git describe`; fetchFromGitHub omits .git.
  postPatch = ''
    substituteInPlace version.go \
      --replace-fail 'const Version = "0.0.20250522"' 'const Version = "v${version}"'
  '';

  vendorHash = "sha256-Y2dCwlKMVLrkzDcNKyCPxFJwMbCA2mQKkakvzwbamCY=";
  subPackages = ["."];
  # Nix's vendoring exposes dependency sources to this repository-wide formatting test.
  checkFlags = ["-skip=TestFormatting"];

  meta.platforms = lib.platforms.linux;
}
