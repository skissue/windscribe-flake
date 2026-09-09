{
  description = "Windscribe desktop — compile-only Nix build";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    wsOpenSSL = pkgs.callPackage ./nix/deps/openssl.nix {};
    wsOpenVPN = pkgs.callPackage ./nix/deps/openvpn.nix {inherit wsOpenSSL;};
    wsAmneziaWG = pkgs.callPackage ./nix/deps/amneziawg-go.nix {};
    wsCurl = pkgs.callPackage ./nix/deps/curl.nix {inherit wsOpenSSL;};
    skyr = pkgs.callPackage ./nix/deps/skyr-url.nix {};
    wsnet = pkgs.callPackage ./nix/deps/wsnet.nix {inherit wsOpenSSL wsCurl skyr;};
  in {
    packages.x86_64-linux.default = pkgs.callPackage ./nix/package.nix {
      src = self;
      inherit wsnet wsOpenSSL wsOpenVPN wsAmneziaWG skyr;
    };
    nixosModules.default = {
      lib,
      pkgs,
      ...
    }: {
      imports = [./nix/module.nix];
      services.windscribe.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
    };
    checks.x86_64-linux.runtime = import ./nix/tests/runtime.nix {
      inherit pkgs;
      module = self.nixosModules.default;
      windscribe = self.packages.x86_64-linux.default;
    };
  };
}
