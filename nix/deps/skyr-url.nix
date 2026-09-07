{
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  nlohmann_json,
  range-v3,
  tl-expected,
}:
stdenv.mkDerivation {
  pname = "skyr-url";
  version = "1.13.0";
  src = fetchFromGitHub {
    owner = "cpp-netlib";
    repo = "url";
    rev = "v1.13.0";
    hash = "sha256-f+WcXdvsIGfXUIIK039DP3GS/BzOMbx9lH0G2ZM9NOg=";
  };
  nativeBuildInputs = [cmake ninja];
  propagatedBuildInputs = [nlohmann_json range-v3 tl-expected];
  cmakeFlags = [
    "-Dskyr_BUILD_DOCS=OFF"
    "-Dskyr_BUILD_EXAMPLES=OFF"
    "-Dskyr_BUILD_TESTS=OFF"
    "-Dskyr_ENABLE_FILESYSTEM_FUNCTIONS=OFF"
    "-Dskyr_WARNINGS_AS_ERRORS=OFF"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  ];
}
