#!/usr/bin/env bash
# Reproducible opt-in smoke run. Source identity is captured outside the app
# test host because Git's Desktop traversal may block under macOS TCC.
set -euo pipefail
cd "$(dirname "$0")/.."
build_args=()
if [[ -n "${PDFTOOLS_BUILD_DIR:-}" ]]; then
  build_args=(-derivedDataPath "$PDFTOOLS_BUILD_DIR")
fi
xcodebuild build-for-testing -project PDFTools.xcodeproj -scheme PDFTools \
  -destination 'platform=macOS,arch=arm64' ${build_args[@]+"${build_args[@]}"}
manifest=$(mktemp /tmp/pdftools-source-baseline.XXXXXX)
qpdf_probe=$(mktemp /tmp/pdftools-qpdf.XXXXXX)
cp Vendor/qpdf/qpdf "$qpdf_probe"
chmod +x "$qpdf_probe"
trap 'rm -f "$manifest" "$qpdf_probe"' EXIT
export TEST_RUNNER_PDFTOOLS_SMOKE_QPDF="$qpdf_probe"
python3 - "$manifest" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
root=Path.cwd()
paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z',
    'PDFTools','PDFToolsTests','PDFTools.xcodeproj','Vendor','Scripts']).split(b'\0')
hash_=hashlib.sha256()
for path in sorted({root / p.decode() for p in paths if p}):
    if not path.exists():
        continue
    hash_.update(str(path).encode())
    with path.open('rb') as file:
        while chunk := file.read(1 << 20): hash_.update(chunk)
identity={'git_commit':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),
    'git_dirty':'true' if subprocess.check_output(['git','status','--porcelain']) else 'false',
    'source_and_vendor_sha256':hash_.hexdigest()}
Path(sys.argv[1]).write_text(json.dumps(identity,indent=2,sort_keys=True)+'\n')
PY
export TEST_RUNNER_PDFTOOLS_BASELINE_SOURCE_MANIFEST="$manifest"
export TEST_RUNNER_PDFTOOLS_SMOKE=1
xcodebuild test-without-building -project PDFTools.xcodeproj -scheme PDFTools \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:PDFToolsTests/CompressionSmokeBenchmark ${build_args[@]+"${build_args[@]}"}
