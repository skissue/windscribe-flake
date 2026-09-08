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
    wsCurl = pkgs.callPackage ./nix/deps/curl.nix {inherit wsOpenSSL;};
    skyr = pkgs.callPackage ./nix/deps/skyr-url.nix {};
    wsnet = pkgs.callPackage ./nix/deps/wsnet.nix {inherit wsOpenSSL wsCurl skyr;};
  in {
    packages.x86_64-linux.default = pkgs.callPackage ./nix/package.nix {
      src = self;
      inherit wsnet wsOpenSSL skyr;
    };
    checks.x86_64-linux.gai = import ./nix/tests/gai.nix {
      inherit pkgs;
      windscribe = self.packages.x86_64-linux.default;
    };
  };
}
