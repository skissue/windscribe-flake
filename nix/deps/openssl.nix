{
  openssl,
  fetchFromGitHub,
}:
# Keep Windscribe's TLS behavior, not just the APIs needed to compile wsnet.
openssl.overrideAttrs {
  version = "4.0.3";
  src = fetchFromGitHub {
    owner = "openssl";
    repo = "openssl";
    rev = "openssl-4.0.3";
    hash = "sha256-7h7s/mznobOfDHhZOlSg9A9Jvh70MhcSH6Ilb8Ytj/I=";
  };
  patches = [../sources/registry/ports/openssl/tls-padding.patch];
  postPatch = "patchShebangs Configure";
}
