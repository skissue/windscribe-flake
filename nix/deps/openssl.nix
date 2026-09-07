{
  openssl,
  fetchFromGitHub,
}:
# Keep Windscribe's TLS behavior, not just the APIs needed to compile wsnet.
openssl.overrideAttrs {
  version = "4.0.1";
  src = fetchFromGitHub {
    owner = "openssl";
    repo = "openssl";
    rev = "openssl-4.0.1";
    hash = "sha256-HHz0tUteYhZNIZ/j47VDCshacx8JOII4ldKQ7cV0qp0=";
  };
  patches = [../sources/registry/ports/openssl/tls-padding.patch];
  postPatch = "patchShebangs Configure";
}
