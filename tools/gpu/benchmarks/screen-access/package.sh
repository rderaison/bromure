#!/bin/bash
set -euo pipefail
# Preserve the full package.sh-built signed app; benchmark scripts sit alongside it.
source_app="${1:?Usage: package.sh /path/to/Bromure.app [output directory] [private candidate image directory]}"
output="${2:-$HOME/Desktop/Bromure Screen Benchmark}"
candidate_image="${3:-}"
script_dir=$(cd "$(dirname "$0")" && pwd)
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$source_app"
mkdir -p "$output/suite"
/usr/bin/ditto "$source_app" "$output/Bromure.app"
cp "$script_dir"/{run.py,guest.py,visible.js,compare.py,README.md} "$output/suite/"
cp "$script_dir/../webgl2-workload.js" "$output/suite/"
if [[ -n "$candidate_image" ]]; then
    mkdir "$output/Test image"
    for name in linux-base.img vmlinuz initrd image-version image-state.json graphics-capabilities.json; do
        [[ -f "$candidate_image/$name" ]] || { echo "Missing candidate file: $name" >&2; exit 1; }
        cp -c "$candidate_image/$name" "$output/Test image/$name" 2>/dev/null || cp "$candidate_image/$name" "$output/Test image/$name"
    done
    echo 'Private patched test image. Original catalog/version metadata is preserved; this is not a published image 501.' > "$output/Test image/PRIVATE-CANDIDATE.txt"
fi
for access in local remote headless; do
    cat > "$output/Run $access.command" <<EOF
#!/bin/bash
set -euo pipefail
cd "\$(dirname "\$0")"
args=(--app "\$PWD/Bromure.app" --access "$access" --output "\$HOME/Desktop/Bromure benchmarks")
if [[ -d "\$PWD/Test image" ]]; then args+=(--storage-dir "\$PWD/Test image" --allow-candidate-image); fi
if [[ "$access" == remote ]]; then args+=(--remote-client "\${BROMURE_REMOTE_CLIENT:-macOS Screen Sharing}"); fi
/usr/bin/python3 suite/run.py "\${args[@]}" "\$@"
echo 'Finished. Results are on your Desktop.'
read -r -p 'Press Return to close.'
EOF
    chmod +x "$output/Run $access.command"
done
/usr/bin/codesign --verify --deep --strict "$output/Bromure.app"
echo "$output"
