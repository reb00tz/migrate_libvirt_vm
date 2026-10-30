#!/usr/bin/env bash
#
# migrate_libvirt_vm.sh — portable KVM VM migration/clone bundle
#
#   Usage: ./migrate_libvirt_vm.sh <vm_name> [output_dir] [--dry-run]
#
#   SCRIPT VERSION 1.0
#
#   REQUIREMENTS / SUPPORTED SCOPE
#   - libvirt versions supported: libvirt 10.x–11.x
#   - Source VM MUST already be fully shut down before this script runs.
#   - Restoration assumes no existing VM with same name, or if exists, will be
#     destroyed and forcibly overrwritten without further warnings.
#   - Disk types supported: local libvirt file, volume, and block sources only.
#   - Assumes the default virsh connection is the local system libvirt instance
#     (normally qemu:///system); host paths and the default swtpm state path must
#     belong to that same instance.
#   - Python 3, virsh, qemu-img, GNU coreutils and GNU grep are required.
#   - Target is a clone: restore.sh generates a fresh domain UUID for each restore,
#     MAC addresses and other guest-identifying configuration are preserved - i.e.
#     *** DO NOT RESTORE AND RUN ON THE SAME NETWORK WHERE CLONE SOURCE EXISTS ***
#   - Standard libvirt swtpm state location is assumed when the TPM XML does not
#     explicitly identify a state path: /var/lib/libvirt/swtpm/<domain-UUID>.
#   - Only emulated swtpm state is packaged. Passthrough/external TPM backends
#     are not portable and cause export to stop. Explicit TPM <source> paths
#     require a target libvirt version that supports them (10.10+).
#   - Encrypted disk payloads are copied byte-for-byte rather than flattened.
#     Non-private libvirt secret values can be bundled; private=yes secret values
#     cannot be retrieved through libvirt and must be provisioned independently
#     on the target before the VM is started.
#   - Any secrets will be saved in unencrypted and unprotected form; it is on the
#     user to protect all output files post-export as required.
#   - The bundle is intended for a cold clone/migration to a target with compatible
#     architecture, machine type, firmware, CPU features, and required host devices.
#
#   Produces:
#     <output_dir>/
#       - domain.xml       portable libvirt XML (bundle-relative paths; no source UUID)
#       - disks/           flattened unencrypted disks; byte-preserved encrypted disks
#       - firmware/        NVRAM, pflash, loader, firmware/template files
#       - media/           CD-ROM / floppy images
#       - pmem/            persistent-memory images
#       - tpm/             emulated TPM state when present
#       - acpi/            ACPI table files
#       - fwcfg/           fw_cfg files
#       - pstore/          pstore files
#       - secrets/         referenced secret definitions and exportable base64 values
#       - networks/        network XML definitions
#       - nwfilters/       nwfilter XML definitions
#       - hostdeps.txt     host environment report
#       - manifest.txt     file manifest
#       - SHA256SUMS       checksums of the final bundle contents
#       - README.txt       restore requirements and instructions
#       - restore.sh       restoration script
#
#   This is not a generic all-device migration engine. The VM must use only
#   the disk source types listed above; other disk types/host-specific resources
#   are outside scope and are not made portable by this script. Missing required
#   file, volume, block, firmware, secret, or emulated-TPM resources abort export.
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------
#  helpers
# ---------------------------------------------------------------
info()  { echo "  [i] $*"; }
warn()  { echo "  [!] $*" >&2; }
action() { echo "  >> $*"; }
usage() {
    cat <<'USAGE'
Usage: migrate_libvirt_vm.sh <vm_name> [output_dir] [--dry-run]

  <vm_name>    name of the defined, fully shut-down libvirt domain
  [output_dir] destination directory (default: ./<vm_name>-bundle)
  --dry-run    show what would be copied without writing files
USAGE
    exit "${1:-0}"
}

# ---------------------------------------------------------------
#  arguments
# ---------------------------------------------------------------
DRY_RUN=0
VM_NAME=""
OUTPUT_DIR=""
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        -*)         ;;  # ignore other flags
        *)
            if [[ -z "$VM_NAME" ]]; then
                VM_NAME="$arg"
            elif [[ -z "$OUTPUT_DIR" ]]; then
                OUTPUT_DIR="$arg"
            fi
            ;;
    esac
done
[[ -n "$VM_NAME" ]] || usage 1

# Create individually named scratch files, not a temporary working directory.
# --dry-run therefore creates no directories; scratch files are removed on exit.
TMP_FILES=()
cleanup_tmp() {
    if (( ${#TMP_FILES[@]} > 0 )); then
        rm -f -- "${TMP_FILES[@]}"
    fi
}
trap cleanup_tmp EXIT

new_tmp_file() {
    local var_name="$1" tmp_path
    tmp_path="$(mktemp "${TMPDIR:-/tmp}/migrate_vm.XXXXXX")"
    printf -v "$var_name" '%s' "$tmp_path"
    TMP_FILES+=("$tmp_path")
}

new_tmp_file MANIFEST_FILE
new_tmp_file DOMAIN_XML
new_tmp_file HOSTDEP_SCAN
new_tmp_file DISK_MAP
new_tmp_file DISK_REWRITE_MAP
new_tmp_file MEDIA_MAP
new_tmp_file PMEM_MAP
new_tmp_file FWCFG_MAP
new_tmp_file ACPI_MAP
new_tmp_file PORTABLE_XML
new_tmp_file ROM_MAP
new_tmp_file CHARDEV_MAP
new_tmp_file PSTORE_MAP
new_tmp_file TPM_MAP
new_tmp_file PF_MAP
new_tmp_file FIRMWARE_MAP
: > "$MANIFEST_FILE"
: > "$TPM_MAP"
: > "$PF_MAP"
: > "$FIRMWARE_MAP"
: > "$ACPI_MAP"
PRIVATE_SECRETS_LIST=""

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="./${VM_NAME}-bundle"
fi
if (( ! DRY_RUN )) && [[ -e "$OUTPUT_DIR" && -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
    echo "ERROR: output dir '$OUTPUT_DIR' already exists and is not empty" >&2
    exit 1
fi

add_manifest() {
    echo "$@" >> "$MANIFEST_FILE"
}

# Resolve file payloads to their final regular-file target before packaging.
# This prevents cp -a from preserving source-host symlinks in the bundle.
resolve_payload_file() {
    local src="$1" resolved
    resolved="$(realpath -e -- "$src" 2>/dev/null)" || {
        echo "ERROR: cannot resolve required payload: $src" >&2
        return 1
    }
    [[ -f "$resolved" ]] || {
        echo "ERROR: payload is not a regular file: $src (resolved: $resolved)" >&2
        return 1
    }
    printf '%s' "$resolved"
}

copy_payload_file() {
    local src="$1" dest="$2" resolved
    resolved="$(resolve_payload_file "$src")" || return 1
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$resolved" "$dest"
}

copy_file_with_manifest() {
    local src="$1" dest_dir="$2" label="${3:-}"
    if (( ! DRY_RUN )); then
        mkdir -p "$dest_dir"
        copy_payload_file "$src" "$dest_dir/$(basename "$src")"
    fi
    add_manifest "$(basename "$dest_dir")/$(basename "$src")" "${label:-from $src}"
}

require_source_vm_shut_off() {
    local context="${1:-preflight}" state
    if ! state="$(virsh domstate "$VM_NAME" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; then
        echo "ERROR: unable to determine state of source domain '$VM_NAME' ($context)." >&2
        return 1
    fi
    case "${state,,}" in
        "shut off"|"shutoff") ;;
        *)
            echo "ERROR: source VM '$VM_NAME' must be fully shut off before export; current state: '${state:-unknown}' ($context)." >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------
#  0  preflight
# ---------------------------------------------------------------
echo "==> Preflight"
command -v virsh    >/dev/null 2>&1 || { echo "ERROR: virsh not found"    >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "ERROR: qemu-img not found" >&2; exit 1; }

if ! virsh domstate "$VM_NAME" >/dev/null 2>&1; then
    echo "ERROR: domain '$VM_NAME' not found (is it defined?)" >&2
    exit 1
fi
require_source_vm_shut_off "initial preflight"

virsh dumpxml "$VM_NAME" > "$DOMAIN_XML"
require_source_vm_shut_off "after domain XML capture"

# extract the VM UUID early — needed for TPM paths and secrets
DOMAIN_UUID="$(python3 -c "
import xml.etree.ElementTree as ET
root = ET.parse('$DOMAIN_XML').getroot()
u = root.find('./uuid')
print(u.text.strip() if u is not None else '')
")"

# capture host environment
{
    echo "# Host environment report"
    echo "# captured $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    echo "## kernel"
    uname -a 2>/dev/null || true
    echo ""
    echo "## libvirt"
    virsh version 2>/dev/null || true
    echo ""
    echo "## QEMU"
    qemu-system-x86_64 --version 2>/dev/null | head -3 || true
    QEMU_BIN="$(qemu-system-x86_64 --version 2>/dev/null | head -1 || true)"
    [[ -n "$QEMU_BIN" ]] && echo "$QEMU_BIN" || true
    echo ""
    echo "## modules (kvm, vfio, vhost, nvdimm, swtpm)"
    for mod in $(lsmod 2>/dev/null | awk '{print $1}'); do
        case "$mod" in
            kvm*|vfio*|vhost*|nvdimm*|swtpm*)
                echo "  $mod"
                ;;
        esac
    done
    echo ""
    echo "## key packages"
    for pkg in qemu-kvm libvirt libosinfo swift tpmtop swtpm swtpm-tools; do
        if command -v "${pkg}" >/dev/null 2>&1; then
            echo "  $pkg: $(command -v "$pkg")"
        fi
    done
    dpkg -l 2>/dev/null | grep -E 'qemu|libvirt|swtpm|tpm' | awk '{print "  "$2" "$3}' || true
    echo ""
    echo "## CPU"
    grep -m1 'model name' /proc/cpuinfo 2>/dev/null || true
    nproc 2>/dev/null | xargs -I{} echo "  cores: {}"
    echo ""
    echo "## memory"
    grep -m1 MemTotal /proc/meminfo 2>/dev/null || true
    echo ""
    echo "## disk (VM's storage backing)"
    lsblk 2>/dev/null | head -30 || true
} > "$HOSTDEP_SCAN" 2>/dev/null || true

# ---------------------------------------------------------------
#  1  disks
# ---------------------------------------------------------------
echo ""
echo "==> Disks"

DISK_COUNTER=0
: > "$DISK_MAP"
if (( ! DRY_RUN )); then
    mkdir -p "${OUTPUT_DIR}/disks" 2>/dev/null || true
fi

# Build disk list from standard libvirt XML. XML indexes are stable even if a source is missing.
DISK_ENTRIES="$(python3 - "$DOMAIN_XML" <<'PYEOF_DISKS'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
xml_index = 0
os_el = root.find('./os')
loader = os_el.find('./loader') if os_el is not None else None
pflash_loader = (loader.text or '').strip() if loader is not None and loader.get('type') == 'pflash' and loader.text else ''
for dev in root.iter('disk'):
    mode = dev.get('device', 'disk')
    if mode in ('cdrom', 'floppy'):
        continue
    src = dev.find('./source')
    stype = dev.get('type', '')
    if src is None or stype not in ('file', 'volume', 'block'):
        continue
    source_path = src.get('file', src.get('path', '')) if stype == 'file' else (src.get('dev', src.get('path', '')) if stype == 'block' else '')
    target = dev.find('./target')
    target_dev = target.get('dev', '') if target is not None else ''
    # pflash code devices are firmware, not guest data disks.
    if stype == 'file' and source_path and (source_path == pflash_loader or target_dev.lower().startswith('pflash')):
        continue
    xml_index += 1
    enc = src.find('./encryption')
    if enc is None:
        enc = dev.find('./encryption')
    encrypted = 'yes' if enc is not None else 'no'
    enc_attr = enc.get('format', '') if enc is not None else ''
    driver = dev.find('./driver')
    driver_fmt = driver.get('type', '') if driver is not None else ''
    if stype == 'file':
        fields = (xml_index, 'file', mode, src.get('file', src.get('path', '')), '', enc_attr, encrypted, driver_fmt)
    elif stype == 'volume':
        fields = (xml_index, 'volume', mode, src.get('pool', ''), src.get('volume', ''), enc_attr, encrypted, driver_fmt)
    else:
        fields = (xml_index, 'block', mode, src.get('dev', src.get('path', '')), '', enc_attr, encrypted, driver_fmt)
    print('\x1f'.join(str(x) for x in fields))
PYEOF_DISKS
)"

# helper: resolve a storage-volume to its on-disk path
resolve_vol() {
    local pool="$1" vol="$2"
    local xml path
    xml="$(virsh vol-dumpxml --pool "$pool" "$vol" 2>/dev/null || true)"
    path="$(grep -oP '(?<=<path>)[^<]+' <<<"$xml" | head -1 || true)"
    if [[ -z "$path" && "$pool" == "default" ]]; then
        path="/var/lib/libvirt/images/$vol"
    fi
    printf '%s' "$path"
}

# probe the on-disk format of a file
probe_fmt() {
    local path="$1" out
    out="$(qemu-img info --output=json "$path" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format", "unknown"))' 2>/dev/null || true)"
    echo "${out:-unknown}"
}

# Flatten one source image to qcow2, using the detected source format when known.
flatten_disk() {
    local src="$1" dest="$2" fmt="${3:-unknown}"
    if [[ "$fmt" != "unknown" ]] && qemu-img convert -p -f "$fmt" -O qcow2 "$src" "$dest" 2>/dev/null; then
        :
    elif qemu-img convert -p -O qcow2 "$src" "$dest" 2>/dev/null; then
        :
    else
        warn "failed to flatten $src to $dest (source format: $fmt)"
        return 1
    fi
    if ! qemu-img check "$dest"; then
        echo "ERROR: qemu-img check failed for converted disk image: $dest" >&2
        return 1
    fi
}

while IFS=$'\x1f' read -r dxmlidx dkind dmode dpool dvol dench dencrypted ddriverfmt; do
    [[ -z "$dkind" ]] && continue

    local_src_path=""
    if [[ "$dkind" == "file" ]]; then
        local_src_path="$dpool"
    elif [[ "$dkind" == "volume" ]]; then
        local_src_path="$(resolve_vol "$dpool" "$dvol")"
        [[ -n "$local_src_path" ]] || { echo "ERROR: cannot resolve volume $dvol in pool $dpool" >&2; exit 1; }
    elif [[ "$dkind" == "block" ]]; then
        local_src_path="$dpool"
    fi

    if [[ -z "$local_src_path" ]]; then
        echo "ERROR: disk source is empty (kind=$dkind, XML index=$dxmlidx)" >&2
        exit 1
    fi
    if [[ ! -e "$local_src_path" ]]; then
        echo "ERROR: required disk source not found: $local_src_path" >&2
        exit 1
    fi

    DISK_COUNTER=$((DISK_COUNTER + 1))
    info "disk #$DISK_COUNTER  ($dkind, $dmode)  $local_src_path"
    fmt="$(probe_fmt "$local_src_path")"
    info "  probed format: $fmt; XML driver format: ${ddriverfmt:-unspecified}"

    if [[ "$dencrypted" == "yes" ]]; then
        local_dest="${OUTPUT_DIR}/disks/disk_${DISK_COUNTER}.encrypted.img"
        info "  encrypted source: preserving bytes and encryption XML (not flattening)"
    else
        local_dest="${OUTPUT_DIR}/disks/disk_${DISK_COUNTER}.qcow2"
    fi
    add_manifest "disks/$(basename "$local_dest")" "from $local_src_path (probed format: $fmt; encrypted=$dencrypted)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$dxmlidx" "$local_src_path" "$local_dest" "${ddriverfmt:-__UNSPECIFIED__}" "$dencrypted" >> "$DISK_MAP"

    if (( ! DRY_RUN )); then
        if [[ "$dencrypted" == "yes" ]]; then
            if [[ -b "$local_src_path" ]]; then
                dd if="$local_src_path" of="$local_dest" bs=16M iflag=fullblock status=progress conv=fsync
            else
                resolved_disk="$(resolve_payload_file "$local_src_path")"
                cp --sparse=always --reflink=auto -- "$resolved_disk" "$local_dest"
            fi
            [[ -s "$local_dest" ]] || { echo "ERROR: encrypted disk copy is empty: $local_dest" >&2; exit 1; }
        else
            flatten_disk "$local_src_path" "$local_dest" "$fmt" || {
                echo "ERROR: disk conversion or integrity verification failed for $local_src_path" >&2
                exit 1
            }
        fi
    fi
done < <(printf '%s\n' "$DISK_ENTRIES")

# build the rewrite map: XML disk index -> bundle-relative path, format, encrypted flag
while IFS=$'\t' read -r idx src dest driverfmt encrypted; do
    rel="${dest#$OUTPUT_DIR/}"
    printf '%s\t%s\t%s\t%s\n' "$idx" "$rel" "${driverfmt:-__UNSPECIFIED__}" "$encrypted" >> "$DISK_REWRITE_MAP"
done < "$DISK_MAP"

# ---------------------------------------------------------------
#  1b  pflash disks (firmware state)
# ---------------------------------------------------------------
echo ""
echo "==> pflash / firmware state"

PF_DEST_DIR="${OUTPUT_DIR}/firmware"
if (( ! DRY_RUN )); then
    mkdir -p "$PF_DEST_DIR"
fi

PF_ENTRIES="$(python3 - "$DOMAIN_XML" <<'PYEOF_PF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
os_el = root.find('./os')
loader = os_el.find('./loader') if os_el is not None else None
pflash_loader = (loader.text or '').strip() if loader is not None and loader.get('type') == 'pflash' and loader.text else ''
for dev in root.iter('disk'):
    if dev.get('device') not in ('disk', None):
        continue
    src = dev.find('./source')
    if src is None or dev.get('type') != 'file':
        continue
    path = src.get('file', src.get('path', ''))
    target = dev.find('./target')
    target_dev = target.get('dev', '') if target is not None else ''
    if path and (path == pflash_loader or target_dev.lower().startswith('pflash')):
        print(path)
PYEOF_PF
)"

PF_COUNTER=0
while IFS= read -r pf_path; do
    [[ -z "$pf_path" ]] && continue
    [[ -f "$pf_path" ]] || { echo "ERROR: pflash firmware file not found: $pf_path" >&2; exit 1; }
    PF_COUNTER=$((PF_COUNTER + 1))
    pf_base="pflash_${PF_COUNTER}_$(basename "$pf_path")"
    info "pflash  $pf_path"
    add_manifest "firmware/${pf_base}" "from $pf_path"
    printf '%s\t%s\n' "$pf_path" "firmware/${pf_base}" >> "$PF_MAP"
    if (( ! DRY_RUN )); then
        copy_payload_file "$pf_path" "${PF_DEST_DIR}/${pf_base}"
    fi
done < <(printf '%s\n' "$PF_ENTRIES")

# ---------------------------------------------------------------
#  1c  media (cdrom / floppy)
# ---------------------------------------------------------------
echo ""
echo "==> Media (cdrom / floppy)"

MEDIA_DEST_DIR="${OUTPUT_DIR}/media"
if (( ! DRY_RUN )); then
    mkdir -p "$MEDIA_DEST_DIR" 2>/dev/null || true
fi

MEDIA_LIST="$(python3 - "$DOMAIN_XML" <<'PYEOF_MEDIA'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for dev in root.iter('disk'):
    mode = dev.get('device', '')
    if mode not in ('cdrom', 'floppy'):
        continue
    src = dev.find('./source')
    if src is None:
        continue
    stype = dev.get('type', '')
    if stype == 'file':
        path = src.get('file', src.get('path', ''))
        if path:
            print(f"{mode}\tfile\t{path}\t")
    elif stype == 'volume':
        print(f"{mode}\tvolume\t{src.get('pool','')}\t{src.get('volume','')}")
PYEOF_MEDIA
)"

MEDIA_COUNTER=0
: > "$MEDIA_MAP"
while IFS=$'\t' read -r media_mode media_kind media_path media_vol; do
    [[ -z "$media_mode" ]] && continue
    MEDIA_COUNTER=$((MEDIA_COUNTER + 1))
    src_path=""
    media_map_key=""
    if [[ "$media_kind" == "volume" ]]; then
        pool_name="${media_path:-default}"
        vol_name="${media_vol:-}"
        src_path="$(resolve_vol "$pool_name" "$vol_name")"
        media_map_key="volume:${pool_name}/${vol_name}"
    else
        src_path="$media_path"
        media_map_key="file:${src_path}"
    fi
    info "media #$MEDIA_COUNTER  ($media_mode)  $src_path"
    if [[ -f "$src_path" ]]; then
        base="media_${MEDIA_COUNTER}_$(basename "$src_path")"
        add_manifest "media/${base}" "from $src_path"
        if (( ! DRY_RUN )); then
            copy_payload_file "$src_path" "${MEDIA_DEST_DIR}/${base}"
        fi
        printf '%s\t%s\n' "$media_map_key" "media/${base}" >> "$MEDIA_MAP"
    else
        info "  (not present or not a regular file — skipping)"
    fi
done < <(printf '%s\n' "$MEDIA_LIST")

# ---------------------------------------------------------------
#  2  persistent memory / NVDIMM
# ---------------------------------------------------------------
echo ""
echo "==> Persistent memory (NVDIMM)"

PMEM_DEST_DIR="${OUTPUT_DIR}/pmem"
if (( ! DRY_RUN )); then
    mkdir -p "$PMEM_DEST_DIR"
fi
PMEM_COUNTER=0
: > "$PMEM_MAP"

PMEM_LIST="$(python3 - "$DOMAIN_XML" <<'PYEOF_PM'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
def source_path(el):
    src = el.find('./source')
    if src is None:
        return ''
    path_el = src.find('./path')
    path = (path_el.text or '').strip() if path_el is not None and path_el.text else src.get('path', '').strip()
    if not path:
        raise SystemExit('ERROR: memory backing source has no usable file path in <{}>'.format(el.tag))
    return path
for mem in root.iter('memory'):
    path = source_path(mem)
    if path:
        print(path)
for nmem in root.iter('nmem'):
    path = source_path(nmem)
    if path:
        print(path)
PYEOF_PM
)"

while IFS= read -r pmem_path; do
    [[ -z "$pmem_path" ]] && continue
    PMEM_COUNTER=$((PMEM_COUNTER + 1))
    if [[ -f "$pmem_path" ]]; then
        pmem_dest="${PMEM_DEST_DIR}/pmem_${PMEM_COUNTER}.raw"
        info "pmem  $pmem_path"
        add_manifest "pmem/pmem_${PMEM_COUNTER}.raw" "from $pmem_path"
        if (( ! DRY_RUN )); then
            copy_payload_file "$pmem_path" "$pmem_dest"
        fi
        printf '%s\t%s\n' "$pmem_path" "pmem/$(basename "$pmem_dest")" >> "$PMEM_MAP"
    else
        echo "ERROR: required persistent-memory backing file not found or not regular: $pmem_path" >&2
        exit 1
    fi
done < <(printf '%s\n' "$PMEM_LIST")

# ---------------------------------------------------------------
#  3  firmware / NVRAM / loader / NVRAM template
# ---------------------------------------------------------------
echo ""
echo "==> Firmware / NVRAM / loader"

FIRMWARE_DEST_DIR="${OUTPUT_DIR}/firmware"
if (( ! DRY_RUN )); then
    mkdir -p "$FIRMWARE_DEST_DIR"
fi
FW_COUNTER=0
copy_firmware_file() {
    local fpath="$1" label="$2" fbase safe_label rel
    [[ -z "$fpath" ]] && return 0
    if [[ ! -f "$fpath" ]]; then
        echo "ERROR: required firmware file not found: $fpath ($label)" >&2
        return 1
    fi
    FW_COUNTER=$((FW_COUNTER + 1))
    safe_label="$(printf '%s' "$label" | sed 's/[^A-Za-z0-9_-]/_/g')"
    fbase="${safe_label}_${FW_COUNTER}_$(basename "$fpath")"
    rel="firmware/${fbase}"
    info "firmware  $fpath  ($label) -> $rel"
    add_manifest "$rel" "from $fpath ($label)"
    printf '%s\t%s\n' "$fpath" "$rel" >> "$FIRMWARE_MAP"
    if (( ! DRY_RUN )); then
        copy_payload_file "$fpath" "${FIRMWARE_DEST_DIR}/${fbase}"
    fi
}

FIRMWARE_FIELDS="$(python3 - "$DOMAIN_XML" <<'PYEOF_FIRMWARE'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
os_el = root.find('./os')
if os_el is not None:
    nv = os_el.find('./nvram')
    ld = os_el.find('./loader')
    if nv is not None and nv.text and nv.text.strip():
        print('nvram\t' + nv.text.strip())
    if ld is not None and ld.text and ld.text.strip():
        print('loader\t' + ld.text.strip())
    if nv is not None and nv.get('template'):
        print('nvram_template\t' + nv.get('template'))
PYEOF_FIRMWARE
)"
while IFS=$'\t' read -r fw_kind fw_path; do
    [[ -z "$fw_kind" || -z "$fw_path" ]] && continue
    case "$fw_kind" in
        nvram) copy_firmware_file "$fw_path" "NVRAM" ;;
        loader) copy_firmware_file "$fw_path" "loader" ;;
        nvram_template) copy_firmware_file "$fw_path" "NVRAM template" ;;
    esac
done < <(printf '%s\n' "$FIRMWARE_FIELDS")

# ---------------------------------------------------------------
#  4  ACPI tables
# ---------------------------------------------------------------
echo ""
echo "==> ACPI tables"

ACPI_DEST_DIR="${OUTPUT_DIR}/acpi"
if (( ! DRY_RUN )); then
    mkdir -p "$ACPI_DEST_DIR"
fi
: > "$ACPI_MAP"

ACPI_LIST="$(python3 - "$DOMAIN_XML" <<'PYEOF_ACPI'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
def local_name(tag):
    return tag.rsplit('}', 1)[-1] if isinstance(tag, str) else ''
def child_local(element, wanted):
    for child in list(element):
        if local_name(child.tag) == wanted:
            return child
    return None
def emit(label, src):
    if src is None:
        raise SystemExit('ERROR: ACPI resource {} has no source element'.format(label))
    path = (src.get('path') or '').strip()
    if not path:
        raise SystemExit('ERROR: ACPI resource {} has a source element without a path'.format(label))
    print('{}\t{}'.format(label, path))
for dev in root.iter():
    tag = local_name(dev.tag)
    if tag == 'acpi-table':
        emit(dev.get('table_id', 'acpi-table'), child_local(dev, 'source'))
    elif tag in ('acpi-tables', 'acpi-s3', 'acpi-s4', 'acpi-s5'):
        emit(tag, child_local(dev, 'source'))
PYEOF_ACPI
)"

ACPI_COUNTER=0
while IFS=$'\t' read -r acpi_tid acpi_path; do
    [[ -z "$acpi_path" ]] && continue
    # Reuse an existing bundle mapping if the same source path is referenced more than once.
    existing_rel="$(awk -F '\t' -v p="$acpi_path" '$1 == p { print $2; exit }' "$ACPI_MAP")"
    [[ -n "$existing_rel" ]] && continue
    [[ -f "$acpi_path" ]] || { echo "ERROR: required ACPI resource file not found or not regular: $acpi_path" >&2; exit 1; }
    ACPI_COUNTER=$((ACPI_COUNTER + 1))
    safe_tid="$(printf '%s' "${acpi_tid:-unknown}" | sed 's/[^A-Za-z0-9_-]/_/g')"
    base="acpi_${ACPI_COUNTER}_${safe_tid}.tbl"
    info "acpi  ${acpi_tid:-?}  $acpi_path -> acpi/${base}"
    add_manifest "acpi/${base}" "from $acpi_path"
    if (( ! DRY_RUN )); then
        copy_payload_file "$acpi_path" "${ACPI_DEST_DIR}/${base}"
    fi
    printf '%s\t%s\n' "$acpi_path" "acpi/${base}" >> "$ACPI_MAP"
done < <(printf '%s\n' "$ACPI_LIST")

# ---------------------------------------------------------------
#  5  fw_cfg
# ---------------------------------------------------------------
echo ""
echo "==> fw_cfg files"

FWCFG_DEST_DIR="${OUTPUT_DIR}/fwcfg"
if (( ! DRY_RUN )); then
    mkdir -p "$FWCFG_DEST_DIR"
fi

FWCFG_LIST="$(python3 - "$DOMAIN_XML" <<'PYEOF_FWCFG'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for sysinfo in root.iter('sysinfo'):
    if sysinfo.get('type') == 'fwcfg':
        for entry in sysinfo.findall('./entry'):
            path = entry.get('file', '')
            if path:
                print(path)
# Compatibility with nonstandard/older XML variants handled by earlier script versions.
for fw in root.iter('fw_cfg'):
    src = fw.find('./source')
    if src is not None:
        path = (src.get('path', '') or src.get('file', '')).strip()
        if not path:
            raise SystemExit('ERROR: fw_cfg source element has no file path')
        print(path)
PYEOF_FWCFG
)"

FWCFG_COUNTER=0
while IFS= read -r fwcfg_path; do
    [[ -z "$fwcfg_path" ]] && continue
    FWCFG_COUNTER=$((FWCFG_COUNTER + 1))
    if [[ -f "$fwcfg_path" ]]; then
        info "fw_cfg  $fwcfg_path"
        base="fwcfg_${FWCFG_COUNTER}_$(basename "$fwcfg_path")"
        add_manifest "fwcfg/${base}" "from $fwcfg_path"
        if (( ! DRY_RUN )); then
            copy_payload_file "$fwcfg_path" "${FWCFG_DEST_DIR}/${base}"
        fi
        printf '%s\t%s\n' "$fwcfg_path" "fwcfg/${base}" >> "$FWCFG_MAP"
    else
        echo "ERROR: required fw_cfg backing file not found or not regular: $fwcfg_path" >&2
        exit 1
    fi
done < <(printf '%s\n' "$FWCFG_LIST")

# ---------------------------------------------------------------
#  5b pstore files
# ---------------------------------------------------------------
echo ""
echo "==> pstore files"
PSTORE_DEST_DIR="${OUTPUT_DIR}/pstore"
if (( ! DRY_RUN )); then
    mkdir -p "$PSTORE_DEST_DIR"
fi
: > "$PSTORE_MAP"
PSTORE_LIST="$(python3 - "$DOMAIN_XML" <<'PYEOF_PSTORE'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for pstore in root.iter('pstore'):
    path_el = pstore.find('./path')
    path = (path_el.text or '').strip() if path_el is not None and path_el.text else (pstore.get('path') or '').strip()
    if path:
        print(path)
    elif path_el is not None or pstore.get('path') is not None:
        raise SystemExit('ERROR: pstore resource has an empty backing-file path')
PYEOF_PSTORE
)"
PSTORE_COUNTER=0
while IFS= read -r pstore_path; do
    [[ -z "$pstore_path" ]] && continue
    if [[ -f "$pstore_path" ]]; then
        PSTORE_COUNTER=$((PSTORE_COUNTER + 1))
        base="pstore_${PSTORE_COUNTER}_$(basename "$pstore_path")"
        info "pstore  $pstore_path"
        add_manifest "pstore/${base}" "from $pstore_path"
        if (( ! DRY_RUN )); then
            copy_payload_file "$pstore_path" "${PSTORE_DEST_DIR}/${base}"
        fi
        printf '%s\t%s\n' "$pstore_path" "pstore/${base}" >> "$PSTORE_MAP"
    else
        echo "ERROR: required pstore backing file not found or not regular: $pstore_path" >&2
        exit 1
    fi
done < <(printf '%s\n' "$PSTORE_LIST")

# ---------------------------------------------------------------
#  5c TPM state (software emulator only)
# ---------------------------------------------------------------
echo ""
echo "==> TPM state"
TPM_INFO="$(python3 - "$DOMAIN_XML" <<'PYEOF_TPMINFO'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
tpm = root.find('./devices/tpm')
if tpm is None:
    raise SystemExit(0)
backend = tpm.find('./backend')
if backend is None:
    print('unsupported\t\tmissing-backend\t\tno')
    raise SystemExit(0)
kind = backend.get('type', '')
version = backend.get('version', '')
src = backend.find('./source')
explicit = 'yes' if src is not None else 'no'
source_type = src.get('type', '') if src is not None else ''
source_path = src.get('path', '') if src is not None else ''
print('\x1f'.join([kind, version, source_type, source_path, explicit]))
PYEOF_TPMINFO
)"
if [[ -n "$TPM_INFO" ]]; then
    IFS=$'\x1f' read -r TPM_BACKEND TPM_VERSION TPM_SOURCE_TYPE TPM_SOURCE_PATH TPM_SOURCE_EXPLICIT <<< "$TPM_INFO"
    if [[ "$TPM_BACKEND" != "emulator" ]]; then
        echo "ERROR: TPM backend '$TPM_BACKEND' is not portable; only the emulated swtpm backend is supported." >&2
        exit 1
    fi
    TPM_STATE_SOURCE="$TPM_SOURCE_PATH"
    TPM_LAYOUT=""
    if [[ "$TPM_SOURCE_EXPLICIT" != "yes" ]]; then
        if [[ -d "/var/lib/libvirt/swtpm/$DOMAIN_UUID" ]]; then
            TPM_STATE_SOURCE="/var/lib/libvirt/swtpm/$DOMAIN_UUID"
        elif [[ -d "/var/lib/swtpm/$DOMAIN_UUID" ]]; then
            TPM_STATE_SOURCE="/var/lib/swtpm/$DOMAIN_UUID"
        else
            echo "ERROR: TPM emulator is configured but its state directory was not found. Checked /var/lib/libvirt/swtpm/$DOMAIN_UUID and /var/lib/swtpm/$DOMAIN_UUID. Set an explicit TPM source path or correct the host's libvirt swtpm state directory." >&2
            exit 1
        fi
        TPM_SOURCE_TYPE="dir"
        TPM_LAYOUT="default-dir"
    fi
    if [[ "$TPM_SOURCE_TYPE" == "dir" ]]; then
        [[ -d "$TPM_STATE_SOURCE" ]] || { echo "ERROR: TPM state directory not found: $TPM_STATE_SOURCE" >&2; exit 1; }
        if [[ "$TPM_SOURCE_EXPLICIT" == "yes" ]]; then
            TPM_LAYOUT="explicit-dir"
            printf 'dir-explicit\t%s\ttpm/state\n' "$TPM_STATE_SOURCE" >> "$TPM_MAP"
        else
            printf 'dir-default\t%s\ttpm/state\n' "$TPM_STATE_SOURCE" >> "$TPM_MAP"
        fi
        add_manifest "tpm/state/" "emulated TPM state copied from $TPM_STATE_SOURCE"
        add_manifest "tpm/source-mode.txt" "TPM state layout metadata ($TPM_LAYOUT)"
        if (( ! DRY_RUN )); then
            mkdir -p "${OUTPUT_DIR}/tpm/state"
            cp -aL -- "$TPM_STATE_SOURCE"/. "${OUTPUT_DIR}/tpm/state"/
            printf '%s\n' "$TPM_LAYOUT" > "${OUTPUT_DIR}/tpm/source-mode.txt"
        fi
        info "TPM state directory packaged from $TPM_STATE_SOURCE ($TPM_LAYOUT)"
    elif [[ "$TPM_SOURCE_TYPE" == "file" ]]; then
        [[ "$TPM_SOURCE_EXPLICIT" == "yes" ]] || { echo "ERROR: internal error: file-backed TPM source has no explicit path." >&2; exit 1; }
        [[ -f "$TPM_STATE_SOURCE" ]] || { echo "ERROR: file-backed TPM state must be a regular file: $TPM_STATE_SOURCE" >&2; exit 1; }
        TPM_LAYOUT="explicit-file"
        add_manifest "tpm/state.raw" "file-backed emulated TPM state copied from $TPM_STATE_SOURCE"
        add_manifest "tpm/source-mode.txt" "TPM state layout metadata ($TPM_LAYOUT)"
        printf 'file\t%s\ttpm/state.raw\n' "$TPM_STATE_SOURCE" >> "$TPM_MAP"
        if (( ! DRY_RUN )); then
            mkdir -p "${OUTPUT_DIR}/tpm"
            copy_payload_file "$TPM_STATE_SOURCE" "${OUTPUT_DIR}/tpm/state.raw"
            printf '%s\n' "$TPM_LAYOUT" > "${OUTPUT_DIR}/tpm/source-mode.txt"
        fi
        info "File-backed TPM state packaged from $TPM_STATE_SOURCE"
    else
        echo "ERROR: unsupported TPM emulator source type '$TPM_SOURCE_TYPE'; supported source types are dir and file." >&2
        exit 1
    fi
else
    info "No TPM device configured."
fi

# ---------------------------------------------------------------
#  6  host report (final)
# ---------------------------------------------------------------
echo ""
echo "==> Host dependency scan"

{
    echo "# Host dependency report"
    echo "# $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    echo "## kernel"
    uname -a 2>/dev/null || true
    echo ""
    echo "## CPU features (from /proc/cpuinfo)"
    grep -m1 'model name' /proc/cpuinfo 2>/dev/null || true
    grep -m1 flags /proc/cpuinfo 2>/dev/null | \
        awk '{for(i=2;i<=NF;i++) print $i}' | sort -u || true
    echo ""
    echo "## libvirt"
    virsh version 2>/dev/null || true
    echo ""
    echo "## QEMU binary"
    QEMU_BIN="$(qemu-system-x86_64 --version 2>/dev/null | head -1 || true)"
    [[ -n "$QEMU_BIN" ]] && echo "$QEMU_BIN" || echo "(not found)"
    echo ""
    echo "## KVM / VFIO / NVDIMM / swtpm modules"
    for mod in kvm kvm_intel kvm_amd vfio vfio_pci vfio_iommu_type1 \
               nvdimm swtpm tpm_tis; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$mod"; then
            echo "  [loaded]  $mod"
        fi
    done
    echo ""
    echo "## key packages (dpkg)"
    dpkg -l 2>/dev/null | grep -E '^ii\s+(qemu|libvirt|swtpm|tpm)' | awk '{print "  "$2"="$3}' || true
    echo ""
    echo "## VM summary (from domain XML)"
    CPU_MODEL="$(python3 -c "
import xml.etree.ElementTree as ET
root = ET.parse('$DOMAIN_XML').getroot()
c = root.find('./cpu')
print(c.get('mode','') if c is not None else 'unknown')
" 2>/dev/null || true)"
    MEM="$(python3 -c "
import xml.etree.ElementTree as ET
root = ET.parse('$DOMAIN_XML').getroot()
node = root.find('./memory')
if node is not None:
    print('memory={}KiB unit={}'.format(node.text, node.get('unit','KiB')))
" 2>/dev/null || true)"
    [[ -n "$CPU_MODEL" ]] && echo "  cpu mode: $CPU_MODEL"
    [[ -n "$MEM" ]]       && echo "  $MEM"
} > "$HOSTDEP_SCAN"

# Verify the cold-source invariant again after all backing resources have been read.
require_source_vm_shut_off "after payload collection"

# ---------------------------------------------------------------
#  7  build portable domain.xml (relative paths, no uuid)
# ---------------------------------------------------------------
echo ""
echo "==> Building portable domain.xml"

python3 - "$DOMAIN_XML" "$PORTABLE_XML" \
    "$DISK_REWRITE_MAP" \
    "$MEDIA_MAP" \
    "$PMEM_MAP" \
    "$ROM_MAP" \
    "$CHARDEV_MAP" \
    "$PSTORE_MAP" \
    "$FWCFG_MAP" \
    "$ACPI_MAP" \
    "$PF_MAP" \
    "$FIRMWARE_MAP" \
    "$TPM_MAP" \
    "$OUTPUT_DIR" \
    <<'PYREWRITE'
import sys, os, re
import xml.etree.ElementTree as ET

domain_xml, out_xml = sys.argv[1], sys.argv[2]
disk_map_path, media_map_path, pmem_map_path, rom_map_path, chardev_map_path, pstore_map_path, fwcfg_map_path, acpi_map_path, pf_map_path, firmware_map_path, tpm_map_path = sys.argv[3:14]
out_dir = sys.argv[14]   # OUTPUT_DIR (bundle root); every portable-XML path is relative to this

ET.register_namespace('',    'http://libvirt.org/schemas/domain/v1.2')
ET.register_namespace('rtd', 'http://libvirt.org/schemas/ramblock/v0')
ET.register_namespace('s3',  'http://libvirt.org/schemas/s3/v0')
ET.register_namespace('s4',  'http://libvirt.org/schemas/s4/v0')
ET.register_namespace('s5',  'http://libvirt.org/schemas/s5/v0')
ET.register_namespace('acpi','http://libvirt.org/schemas/acpi/v0')

def load_map(path):
    m = {}
    if os.path.isfile(path):
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) >= 2:
                    m[parts[0]] = parts[1]
    return m


def out_rel(abspath, out_dir):
    """Return a path relative to out_dir, or abspath if not under it."""
    try:
        return os.path.relpath(abspath, out_dir)
    except ValueError:
        return abspath

tree = ET.parse(domain_xml)
root = tree.getroot()

# --- strip elements that must not survive migration ---
for tag in ('uuid',):
    el = root.find('./' + tag)
    if el is not None:
        root.remove(el)

# --- rewrite disk and media sources ---
disk_map = {}
if os.path.isfile(disk_map_path):
    with open(disk_map_path, 'r', encoding='utf-8') as f:
        for line in f:
            cols = line.rstrip('\n').split('\t')
            if len(cols) >= 2:
                disk_map[cols[0]] = {
                    'rel': cols[1],
                    'driver_fmt': cols[2] if len(cols) > 2 else '',
                    'encrypted': cols[3] if len(cols) > 3 else 'no',
                }
media_map = load_map(media_map_path)
pf_map = load_map(pf_map_path)
# Recognize pflash-coded device disks before advancing the ordinary-disk index.
os_el = root.find('./os')
loader_el = os_el.find('./loader') if os_el is not None else None
pflash_loader = (loader_el.text or '').strip() if loader_el is not None and loader_el.get('type') == 'pflash' and loader_el.text else ''
disk_idx = 0
for dev in root.iter('disk'):
    src = dev.find('./source')
    if src is None:
        continue
    mode = dev.get('device', 'disk')
    stype = dev.get('type', '')
    if mode in ('cdrom', 'floppy'):
        if stype == 'file':
            old_path = src.get('file', src.get('path', ''))
            media_key = 'file:' + old_path if old_path else ''
        elif stype == 'volume':
            media_key = 'volume:{}/{}'.format(src.get('pool', ''), src.get('volume', ''))
        else:
            media_key = ''
        if media_key and media_key in media_map:
            for attr in ('file', 'dev', 'path', 'pool', 'volume', 'name'):
                src.attrib.pop(attr, None)
            src.set('file', media_map[media_key])
            dev.set('type', 'file')
        continue

    if stype == 'file':
        source_path = src.get('file', src.get('path', ''))
        target = dev.find('./target')
        target_dev = target.get('dev', '') if target is not None else ''
        if source_path in pf_map:
            for attr in ('file', 'dev', 'path', 'pool', 'volume', 'name'):
                src.attrib.pop(attr, None)
            src.set('file', pf_map[source_path])
            dev.set('type', 'file')
            continue
        if source_path and (source_path == pflash_loader or target_dev.lower().startswith('pflash')):
            # A pflash device that was not captured is a hard portability error.
            raise SystemExit('ERROR: pflash source was not packaged: ' + source_path)

    if stype not in ('file', 'block', 'volume'):
        continue
    disk_idx += 1
    entry = disk_map.get(str(disk_idx))
    if entry is None:
        # The exporter must have copied every supported non-media disk.
        raise SystemExit('ERROR: no disk rewrite entry for XML disk index {}'.format(disk_idx))
    new_path = entry['rel']
    for attr in ('file', 'dev', 'path', 'pool', 'volume', 'name'):
        src.attrib.pop(attr, None)
    src.set('file', new_path)
    dev.set('type', 'file')
    driver = dev.find('./driver')
    if entry['encrypted'] == 'yes':
        # Preserve encrypted bytes and their original data driver format; only the
        # host-side source location/type changes from block/volume to a bundle file.
        if driver is not None and entry['driver_fmt'] and entry['driver_fmt'] != '__UNSPECIFIED__':
            driver.set('type', entry['driver_fmt'])
    else:
        if driver is None:
            driver = ET.Element('driver')
            dev.insert(list(dev).index(src), driver)
        driver.set('type', 'qcow2')

# --- rewrite NVRAM, loader, and NVRAM template paths via exact source-path map ---
firmware_map = load_map(firmware_map_path)
for os_el in root.iter('os'):
    for child in list(os_el):
        tag = child.tag.split('}')[-1]
        if tag not in ('loader', 'nvram'):
            continue
        txt = (child.text or '').strip()
        if txt:
            if txt not in firmware_map:
                raise SystemExit('ERROR: firmware path was not packaged: ' + txt)
            child.text = firmware_map[txt]
        if tag == 'nvram' and child.get('template'):
            old_template = child.get('template')
            if old_template not in firmware_map:
                raise SystemExit('ERROR: NVRAM template was not packaged: ' + old_template)
            child.set('template', firmware_map[old_template])

# --- rewrite TPM source paths ---
tpm_records = []
if os.path.isfile(tpm_map_path):
    with open(tpm_map_path, 'r', encoding='utf-8') as f:
        for line in f:
            cols = line.rstrip('\n').split('\t')
            if len(cols) >= 3:
                tpm_records.append(cols[:3])
for tpm in root.iter('tpm'):
    backend = tpm.find('./backend')
    if backend is None or backend.get('type') != 'emulator':
        continue
    src = backend.find('./source')
    if src is None:
        continue
    source_type = src.get('type', '')
    source_path = src.get('path') or ''
    if source_type == 'dir':
        matching = next((r for r in tpm_records if r[0] == 'dir-explicit' and r[1] == source_path), None)
        if matching is None:
            raise SystemExit('ERROR: explicit TPM directory state was not packaged: ' + source_path)
        src.set('path', matching[2])
    elif source_type == 'file':
        matching = next((r for r in tpm_records if r[0] == 'file' and r[1] == source_path), None)
        if matching is None:
            raise SystemExit('ERROR: file-backed TPM state was not packaged: ' + source_path)
        src.set('path', matching[2])
    else:
        raise SystemExit('ERROR: unsupported TPM source type: ' + source_type)

# --- rewrite ACPI tables, persistent memory, pstore, and fw_cfg paths ---
acpi_map = load_map(acpi_map_path)
def local_name(tag):
    return tag.rsplit('}', 1)[-1] if isinstance(tag, str) else ''
def child_local(element, wanted):
    for child in list(element):
        if local_name(child.tag) == wanted:
            return child
    return None
for dev in root.iter():
    tag = local_name(dev.tag)
    if tag not in ('acpi-table', 'acpi-tables', 'acpi-s3', 'acpi-s4', 'acpi-s5'):
        continue
    src = child_local(dev, 'source')
    old_path = (src.get('path') or '').strip() if src is not None else ''
    if old_path:
        if old_path not in acpi_map:
            raise SystemExit('ERROR: ACPI resource was not packaged: ' + old_path)
        src.set('path', acpi_map[old_path])

pmem_map = load_map(pmem_map_path)
for mem in list(root.iter('memory')) + list(root.iter('nmem')):
    src = mem.find('./source')
    if src is None:
        continue
    path_el = src.find('./path')
    old_path = (path_el.text or '').strip() if path_el is not None and path_el.text else (src.get('path') or '').strip()
    if not old_path:
        raise SystemExit('ERROR: memory backing source has no path and cannot be made portable: ' + mem.tag)
    if old_path not in pmem_map:
        raise SystemExit('ERROR: memory backing file was not packaged: ' + old_path)
    new_rel = pmem_map[old_path]
    if path_el is not None:
        path_el.text = new_rel
    else:
        src.set('path', new_rel)

pstore_map = load_map(pstore_map_path)
for dev in root.iter('pstore'):
    path_el = dev.find('./path')
    old_path = (path_el.text or '').strip() if path_el is not None and path_el.text else (dev.get('path') or '').strip()
    if old_path:
        if old_path not in pstore_map:
            raise SystemExit('ERROR: pstore backing file was not packaged: ' + old_path)
        if path_el is not None:
            path_el.text = pstore_map[old_path]
        else:
            dev.set('path', pstore_map[old_path])

fwcfg_map = load_map(fwcfg_map_path)
for sysinfo in root.iter('sysinfo'):
    if sysinfo.get('type') == 'fwcfg':
        for entry in sysinfo.findall('./entry'):
            old_path = (entry.get('file') or '').strip()
            if old_path:
                if old_path not in fwcfg_map:
                    raise SystemExit('ERROR: fw_cfg backing file was not packaged: ' + old_path)
                entry.set('file', fwcfg_map[old_path])
# Compatibility with the nonstandard fw_cfg source form used by earlier script versions.
for dev in list(root.iter('fw_cfg')) + list(root.iter('fwcfg')):
    src = dev.find('./source')
    if src is None:
        continue
    old_path = (src.get('path', '') or src.get('file', '')).strip()
    if old_path:
        if old_path not in fwcfg_map:
            raise SystemExit('ERROR: fw_cfg backing file was not packaged: ' + old_path)
        new_rel = fwcfg_map[old_path]
        if 'path' in src.attrib:
            src.set('path', new_rel)
        else:
            src.set('file', new_rel)

# --- make all remaining absolute paths under out_dir relative ---
# (covers acpi tables, rom files, etc.)
bundle_root = os.path.abspath(out_dir)
def is_under_bundle(path):
    try:
        return os.path.commonpath([bundle_root, os.path.abspath(path)]) == bundle_root
    except (ValueError, OSError):
        return False
for el in root.iter():
    for attr, value in list(el.attrib.items()):
        if value.startswith('/') and is_under_bundle(value):
            el.attrib[attr] = os.path.relpath(value, bundle_root)
for el in root.iter():
    if el.text and el.text.strip().startswith('/') and is_under_bundle(el.text.strip()):
        el.text = os.path.relpath(el.text.strip(), bundle_root)

# --- write ---
os.makedirs(os.path.dirname(out_xml), exist_ok=True)
tree.write(out_xml, xml_declaration=True, encoding='utf-8')
print(f"portable domain.xml written to {out_xml}")
PYREWRITE

# ---------------------------------------------------------------
#  8  networks + nwfilters
# ---------------------------------------------------------------
echo ""
echo "==> Networks"

NET_DEST_DIR="${OUTPUT_DIR}/networks"
if (( ! DRY_RUN )); then
    mkdir -p "$NET_DEST_DIR" 2>/dev/null || true
fi

NET_NAMES="$(python3 - "$DOMAIN_XML" <<'PYEOF_NET'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for iface in root.iter('interface'):
    src = iface.find('./source')
    if src is not None and src.get('network'):
        print(src.get('network'))
PYEOF_NET
)"

while IFS= read -r net_name; do
    [[ -z "$net_name" ]] && continue
    info "network  $net_name"
    if (( DRY_RUN )); then
        # Probe whether the XML can be retrieved without creating an output file.
        if virsh net-dumpxml "$net_name" >/dev/null 2>&1; then
            add_manifest "networks/${net_name}.xml" "from virsh net-dumpxml $net_name"
        else
            warn "cannot dump network $net_name"
        fi
    else
        if virsh net-dumpxml "$net_name" > "${NET_DEST_DIR}/${net_name}.xml" 2>/dev/null; then
            add_manifest "networks/${net_name}.xml" "from virsh net-dumpxml $net_name"
        else
            warn "cannot dump network $net_name"
        fi
    fi
done < <(printf '%s\n' "$NET_NAMES")

QF_DEST_DIR="${OUTPUT_DIR}/nwfilters"
if (( ! DRY_RUN )); then
    mkdir -p "$QF_DEST_DIR" 2>/dev/null || true
fi

QF_NAMES="$(python3 - "$DOMAIN_XML" <<'PYEOF_QF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for iface in root.iter('interface'):
    for f in iface.iter('filterref'):
        print(f.get('filter', ''))
PYEOF_QF
)"

while IFS= read -r qf_name; do
    [[ -z "$qf_name" ]] && continue
    info "nwfilter  $qf_name"
    if (( DRY_RUN )); then
        # Probe whether the XML can be retrieved without creating an output file.
        if virsh nwfilter-dumpxml "$qf_name" >/dev/null 2>&1; then
            add_manifest "nwfilters/${qf_name}.xml" "from virsh nwfilter-dumpxml $qf_name"
        else
            warn "cannot dump nwfilter $qf_name"
        fi
    else
        if virsh nwfilter-dumpxml "$qf_name" > "${QF_DEST_DIR}/${qf_name}.xml" 2>/dev/null; then
            add_manifest "nwfilters/${qf_name}.xml" "from virsh nwfilter-dumpxml $qf_name"
        else
            warn "cannot dump nwfilter $qf_name"
        fi
    fi
done < <(printf '%s\n' "$QF_NAMES")

# ---------------------------------------------------------------
#  9  referenced libvirt secrets
# ---------------------------------------------------------------
echo ""
echo "==> Referenced secrets"

SECRET_DEST_DIR="${OUTPUT_DIR}/secrets"
if (( ! DRY_RUN )); then
    mkdir -p "$SECRET_DEST_DIR"
fi

# Domain XML references secrets as <secret ... uuid='...'> under disk/TPM
# encryption. The secret usage type is not the same thing as its private flag.
SECRET_LIST_XML="$(python3 - "$DOMAIN_XML" <<'PYEOF_SECRETS'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
seen = set()
for secret in root.iter('secret'):
    uuid = secret.get('uuid', '').strip()
    if not uuid or uuid in seen:
        continue
    seen.add(uuid)
    print(uuid + '\t' + secret.get('type', ''))
PYEOF_SECRETS
)"

SECRET_COUNTER=0
while IFS=$'\t' read -r sec_uuid sec_ref_type; do
    [[ -z "$sec_uuid" ]] && continue
    SECRET_COUNTER=$((SECRET_COUNTER + 1))
    info "secret #$SECRET_COUNTER  uuid=$sec_uuid  reference-type=${sec_ref_type:-?}"

    sec_xml="$(virsh secret-dumpxml "$sec_uuid" 2>/dev/null || true)"
    if [[ -z "$sec_xml" ]]; then
        echo "ERROR: domain XML references secret $sec_uuid, but virsh secret-dumpxml failed." >&2
        exit 1
    fi
    sec_meta="$(printf '%s' "$sec_xml" | python3 -c 'import sys,xml.etree.ElementTree as ET; r=ET.parse(sys.stdin).getroot(); u=r.find("./usage"); print("\t".join([r.get("private","no"), r.get("ephemeral","no"), u.get("type","") if u is not None else ""]))')"
    IFS=$'\t' read -r SEC_PRIVATE SEC_EPHEMERAL SEC_USAGE <<< "$sec_meta"
    sec_xml_file="${SECRET_DEST_DIR}/secret_${SECRET_COUNTER}.xml"
    sec_value_file="${SECRET_DEST_DIR}/secret_${SECRET_COUNTER}.value"
    add_manifest "secrets/secret_${SECRET_COUNTER}.xml" "secret $sec_uuid (private=$SEC_PRIVATE ephemeral=$SEC_EPHEMERAL usage=${SEC_USAGE:-unknown})"
    if (( ! DRY_RUN )); then
        printf '%s\n' "$sec_xml" > "$sec_xml_file"
    fi

    if [[ "$SEC_PRIVATE" == "yes" ]]; then
        # Libvirt deliberately refuses to reveal private=yes secret values.
        info "  private=yes: value cannot be exported through libvirt; provision this secret independently on the target."
        PRIVATE_SECRETS_LIST+="  - ${sec_uuid} (secret_${SECRET_COUNTER}.xml)"$'\n'
        continue
    fi

    if (( DRY_RUN )); then
        if ! virsh secret-get-value "$sec_uuid" >/dev/null 2>&1; then
            echo "ERROR: secret $sec_uuid is not private but its value could not be retrieved; encrypted resources cannot be guaranteed portable." >&2
            exit 1
        fi
        add_manifest "secrets/secret_${SECRET_COUNTER}.value" "Base64 secret value (would be exported)"
    else
        # virsh secret-get-value returns Base64 by default; secret-set-value
        # --file expects Base64 unless --plain is specified.
        if virsh -q secret-get-value "$sec_uuid" | tr -d '\r\n' > "$sec_value_file"; then
            if ! python3 - "$sec_value_file" <<'PYEOF_VALIDATE_B64'
import base64, sys
try:
    with open(sys.argv[1], 'rb') as f:
        base64.b64decode(f.read(), validate=True)
except Exception as exc:
    print('invalid base64 secret export: {}'.format(exc), file=sys.stderr)
    raise SystemExit(1)
PYEOF_VALIDATE_B64
            then
                rm -f -- "$sec_value_file"
                echo "ERROR: libvirt returned an invalid Base64 value for secret $sec_uuid." >&2
                exit 1
            fi
            add_manifest "secrets/secret_${SECRET_COUNTER}.value" "Base64 secret value for UUID $sec_uuid"
        else
            rm -f -- "$sec_value_file"
            echo "ERROR: failed to export secret $sec_uuid; refusing to create an incomplete bundle." >&2
            exit 1
        fi
    fi
done < <(printf '%s\n' "$SECRET_LIST_XML" | sort -u)

# ---------------------------------------------------------------
#  10  finalise bundle
# ---------------------------------------------------------------
echo ""
echo "==> Finalising bundle"

if (( ! DRY_RUN )); then
    cp -a "$PORTABLE_XML" "${OUTPUT_DIR}/domain.xml"
    cp -a "$HOSTDEP_SCAN" "${OUTPUT_DIR}/hostdeps.txt"
fi

# README is written before the manifest and checksums so both can cover it.
if (( ! DRY_RUN )); then
    cat > "${OUTPUT_DIR}/README.txt" <<READMEME
VM Migration/Clone Bundle: $VM_NAME
=================================
Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Source host: $(uname -a)

SCOPE AND REQUIREMENTS
  - Source VM was required to be fully shut down before export.
  - Supported guest disk source types: file, volume, block.
- Intended software scope: libvirt 10.x–11.x and QEMU up to 11.1.2.
  - Unencrypted disks are flattened to standalone QCOW2 images.
  - Encrypted disks are copied byte-for-byte and are not flattened.
  - A fresh UUID is generated each time restore.sh is run; MAC addresses remain unchanged.
  - Only emulated swtpm state is packaged. TPM passthrough/external backends are unsupported.
  - Standard target swtpm state location: /var/lib/libvirt/swtpm/<new-domain-UUID>.
  - File-backed TPM source requires target libvirt 10.10 or newer.
  - Host compatibility (CPU, machine type, firmware, network bridges, PCI/USB devices)
    must be checked separately. This bundle does not make host devices portable.

RESTORE
  1. Copy this directory intact to the target host.
  2. Ensure the target has a compatible libvirt/QEMU installation and required host devices.
  3. Run: ./restore.sh
  4. Review restore output and secret warnings before starting the VM.
  5. Start manually with: virsh start "$VM_NAME"

PRIVATE LIBVIRT SECRETS NOT EXPORTED
$PRIVATE_SECRETS_LIST
Private secret values are deliberately not exposed by the libvirt API. Provision each
listed secret out-of-band on the target before starting the VM. For a raw secret file:
  virsh secret-set-value <secret-UUID> --file <secret-file> --plain
Do not place secret material in a command-line argument or an unprotected file.

See hostdeps.txt for source host details and manifest.txt for bundled files.
SHA256SUMS contains checksums for the finalized bundle files (excluding itself).
READMEME
fi

# ---------------------------------------------------------------
#  11  generate restore.sh
# ---------------------------------------------------------------
echo ""
echo "==> Generating restore.sh"

if (( ! DRY_RUN )); then
cat > "${OUTPUT_DIR}/restore.sh" <<RESTORE_EOF
#!/usr/bin/env bash
# Restore/clone the '$VM_NAME' VM bundle on this host.
set -euo pipefail
IFS=\$'\n\t'

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="$VM_NAME"
# New UUID per restoration: this is a clone, not an identity-preserving live migration.
VM_UUID="\$(python3 -c 'import uuid; print(uuid.uuid4())')"
NVRAM_DEST_DIR="/var/lib/libvirt/qemu/nvram"
TPM_DEST_BASE="/var/lib/libvirt/swtpm"

info()  { echo "  [i] \$*"; }
warn()  { echo "  [!] \$*" >&2; }
action() { echo "  >> \$*"; }

 echo "========================================"
echo " Restoring VM: \$VM_NAME"
echo " New domain UUID: \$VM_UUID"
echo " Bundle dir:      \$SCRIPT_DIR"
echo "========================================"

# --- 0. Verify integrity BEFORE changing any host/domain state. ---
if [[ ! -f "\$SCRIPT_DIR/SHA256SUMS" ]]; then
    echo "ERROR: SHA256SUMS is missing; refusing to restore an unverified bundle." >&2
    exit 1
fi
if ! (cd "\$SCRIPT_DIR" && sha256sum -c SHA256SUMS --quiet); then
    echo "ERROR: SHA256 checksum verification failed; refusing to restore." >&2
    exit 1
fi
info "SHA256 checksums verified."

# Check existing secret UUIDs before any destructive domain/network operations.
# A UUID can be shared by other domains, so this restore never changes an existing value.
if [[ -d "\$SCRIPT_DIR/secrets" ]]; then
    for sf in "\$SCRIPT_DIR/secrets/secret_"*.xml; do
        [[ -f "\$sf" ]] || continue
        val_file="\${sf%.xml}.value"
        [[ -f "\$val_file" ]] || continue
        s_uuid="\$(python3 - "\$sf" <<'PYSECRET_PREFLIGHT'
import sys, xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot(); u=r.find('./uuid'); print((u.text or '').strip() if u is not None else '')
PYSECRET_PREFLIGHT
)"
        [[ -n "\$s_uuid" ]] || { echo "ERROR: secret XML has no UUID: \$sf" >&2; exit 1; }
        if virsh secret-dumpxml "\$s_uuid" >/dev/null 2>&1; then
            if ! existing="\$(virsh -q secret-get-value "\$s_uuid" 2>/dev/null | tr -d '\\r\\n')"; then
                echo "ERROR: target secret \$s_uuid already exists but its value cannot be read; refusing to proceed because it may be shared." >&2
                exit 1
            fi
            expected="\$(tr -d '\\r\\n' < "\$val_file")"
            if [[ "\$existing" != "\$expected" ]]; then
                echo "ERROR: target secret \$s_uuid already exists with a different value; refusing to proceed or overwrite it because other domains may share this secret UUID." >&2
                exit 1
            fi
        fi
    done
fi

# --- 1. Existing-domain handling (preserved from v25 behaviour). ---
if virsh domstate "\$VM_NAME" >/dev/null 2>&1; then
    action "Stopping existing VM \$VM_NAME"
    virsh destroy "\$VM_NAME" 2>/dev/null || true
fi
if virsh domstate "\$VM_NAME" >/dev/null 2>&1; then
    action "Undefining existing VM \$VM_NAME"
    virsh undefine "\$VM_NAME" --nvram 2>/dev/null || virsh undefine "\$VM_NAME" 2>/dev/null || true
fi

# --- 2. Networks + nwfilters ---
if [[ -d "\$SCRIPT_DIR/networks" ]]; then
    for nf in "\$SCRIPT_DIR/networks/"*.xml; do
        [[ -f "\$nf" ]] || continue
        nname="\$(python3 - "\$nf" <<'PYNETNAME'
import sys, xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot(); n=r.find('./name'); print((n.text or '').strip() if n is not None else '')
PYNETNAME
)"
        [[ -n "\$nname" ]] || continue
        if virsh net-dumpxml "\$nname" >/dev/null 2>&1; then
            info "network \$nname already exists — leaving as-is"
        else
            action "Defining network \$nname"
            virsh net-define "\$nf"
            virsh net-start "\$nname" || true
        fi
    done
fi
if [[ -d "\$SCRIPT_DIR/nwfilters" ]]; then
    for qf in "\$SCRIPT_DIR/nwfilters/"*.xml; do
        [[ -f "\$qf" ]] || continue
        qf_name="\$(python3 - "\$qf" <<'PYNWFILTER'
import sys, xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot(); print(r.get('name',''))
PYNWFILTER
)"
        [[ -n "\$qf_name" ]] || continue
        if virsh nwfilter-dumpxml "\$qf_name" >/dev/null 2>&1; then
            info "nwfilter \$qf_name already exists — leaving as-is"
        else
            action "Defining nwfilter \$qf_name"
            virsh nwfilter-define "\$qf"
        fi
    done
fi

# --- 3. Define referenced secrets and restore exportable values. ---
if [[ -d "\$SCRIPT_DIR/secrets" ]]; then
    for sf in "\$SCRIPT_DIR/secrets/secret_"*.xml; do
        [[ -f "\$sf" ]] || continue
        val_file="\${sf%.xml}.value"
        s_uuid="\$(python3 - "\$sf" <<'PYSECRETUUID'
import sys, xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot(); u=r.find('./uuid'); print((u.text or '').strip() if u is not None else '')
PYSECRETUUID
)"
        s_private="\$(python3 - "\$sf" <<'PYSECPRIV'
import sys, xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot(); print(r.get('private','no'))
PYSECPRIV
)"
        [[ -n "\$s_uuid" ]] || { warn "secret XML has no UUID: \$sf"; continue; }
        if [[ "\$s_private" == "yes" && ! -f "\$val_file" ]]; then
            warn "private secret \$s_uuid was not exported; independently provision its value before starting the VM"
        fi
        if virsh secret-dumpxml "\$s_uuid" >/dev/null 2>&1; then
            if [[ -f "\$val_file" ]]; then
                if ! existing="\$(virsh -q secret-get-value "\$s_uuid" 2>/dev/null | tr -d '\\r\\n')"; then
                    echo "ERROR: target secret \$s_uuid already exists but its value cannot be read; refusing to replace a potentially shared secret." >&2
                    exit 1
                fi
                expected="\$(tr -d '\\r\\n' < "\$val_file")"
                if [[ "\$existing" != "\$expected" ]]; then
                    echo "ERROR: target secret \$s_uuid already exists with a different value; refusing to overwrite it because other domains may share this secret UUID. Resolve the conflict manually before restoring." >&2
                    exit 1
                else
                    info "secret \$s_uuid already matches; leaving existing secret untouched"
                fi
            else
                info "secret \$s_uuid already exists; no value was bundled"
            fi
        else
            action "Defining secret \$s_uuid"
            virsh secret-define "\$sf"
            if [[ -f "\$val_file" ]]; then
                virsh secret-set-value "\$s_uuid" --file "\$val_file"
            fi
        fi
    done
fi

# --- 4. Restore TPM state under the new domain UUID. ---
tpm_source_mode=""
if [[ -f "\$SCRIPT_DIR/tpm/source-mode.txt" ]]; then
    tpm_source_mode="\$(cat "\$SCRIPT_DIR/tpm/source-mode.txt")"
fi
require_libvirt_10_10() {
    local target_libvirt
    target_libvirt="\$(virsh version 2>/dev/null | sed -n 's/.*Using library: libvirt[[:space:]]\\+//p' | head -1)"
    if [[ -z "\$target_libvirt" ]] || ! python3 - "\$target_libvirt" <<'PYLIBVIRTVER'
import re, sys
m=re.match(r'^(\\d+)\\.(\\d+)', sys.argv[1])
raise SystemExit(0 if m and tuple(map(int,m.groups())) >= (10,10) else 1)
PYLIBVIRTVER
    then
        echo "ERROR: explicit TPM source paths require target libvirt 10.10 or newer (reported: \${target_libvirt:-unknown})." >&2
        exit 1
    fi
}
case "\$tpm_source_mode" in
    default-dir)
        action "Restoring default-layout emulated TPM state for UUID \$VM_UUID"
        mkdir -p "\$TPM_DEST_BASE/\$VM_UUID"
        cp -a "\$SCRIPT_DIR/tpm/state"/. "\$TPM_DEST_BASE/\$VM_UUID"/
        ;;
    explicit-dir)
        require_libvirt_10_10
        action "Restoring explicit-directory emulated TPM state for UUID \$VM_UUID"
        mkdir -p "\$TPM_DEST_BASE/\$VM_UUID/state"
        cp -a "\$SCRIPT_DIR/tpm/state"/. "\$TPM_DEST_BASE/\$VM_UUID/state"/
        ;;
    explicit-file)
        require_libvirt_10_10
        action "Restoring file-backed emulated TPM state for UUID \$VM_UUID"
        mkdir -p "\$TPM_DEST_BASE/\$VM_UUID"
        cp -a "\$SCRIPT_DIR/tpm/state.raw" "\$TPM_DEST_BASE/\$VM_UUID/state.raw"
        ;;
    "") ;;
    *) echo "ERROR: unknown TPM state layout: \$tpm_source_mode" >&2; exit 1 ;;
esac

# --- 5. Build a target-specific XML with a fresh UUID and host absolute paths. ---
restore_xml="\$(mktemp "\${TMPDIR:-/tmp}/restore_domain.XXXXXX.xml")"
trap 'rm -f -- "\$restore_xml"' EXIT
python3 - "\$SCRIPT_DIR/domain.xml" "\$restore_xml" "\$SCRIPT_DIR" "\$VM_UUID" "\$NVRAM_DEST_DIR" "\$TPM_DEST_BASE/\$VM_UUID/state" "\$TPM_DEST_BASE/\$VM_UUID/state.raw" <<'PYRESTOREXML'
import os, sys, shutil, xml.etree.ElementTree as ET
src_xml, dst_xml, bundle, new_uuid, nvram_dir, tpm_dir_dest, tpm_file_dest = sys.argv[1:8]
bundle = os.path.abspath(bundle)
tree = ET.parse(src_xml)
root = tree.getroot()

# This bundle intentionally creates a clone identity. Insert the generated UUID
# in schema order (immediately after <name> if present).
old = root.find('./uuid')
if old is not None:
    root.remove(old)
uuid_el = ET.Element('uuid'); uuid_el.text = new_uuid
name_el = root.find('./name')
root.insert(list(root).index(name_el) + 1 if name_el is not None else 0, uuid_el)

# A clone must get its own writable NVRAM copy, not use the bundle copy.
os_el = root.find('./os')
if os_el is not None:
    nvram = os_el.find('./nvram')
    if nvram is not None and nvram.text and nvram.text.strip():
        nvpath = nvram.text.strip()
        source = nvpath if os.path.isabs(nvpath) else os.path.abspath(os.path.join(bundle, nvpath))
        if not os.path.isfile(source):
            raise SystemExit('ERROR: bundled NVRAM file is missing: ' + source)
        os.makedirs(nvram_dir, exist_ok=True)
        dest = os.path.join(nvram_dir, new_uuid + '_VARS.fd')
        if os.path.exists(dest):
            raise SystemExit('ERROR: target NVRAM path already exists: ' + dest)
        shutil.copy2(source, dest)
        nvram.text = dest

# File-backed swtpm has an explicit XML path; point it at the target copy.
for tpm in root.iter('tpm'):
    backend = tpm.find('./backend')
    if backend is None or backend.get('type') != 'emulator':
        continue
    src = backend.find('./source')
    if src is not None and src.get('type') == 'dir':
        src.set('path', tpm_dir_dest)
    elif src is not None and src.get('type') == 'file':
        src.set('path', tpm_file_dest)

# Resolve any bundle-relative source attributes/elements (including loader and
# nvram template). Device /dev paths that are already absolute remain unchanged.
for el in root.iter():
    tag = el.tag.split('}')[-1]
    for attr in ('file', 'path', 'template'):
        value = el.get(attr)
        if value and not os.path.isabs(value):
            el.set(attr, os.path.abspath(os.path.join(bundle, value)))
    if tag in ('path', 'loader', 'nvram') and el.text and el.text.strip() and not os.path.isabs(el.text.strip()):
        el.text = os.path.abspath(os.path.join(bundle, el.text.strip()))
# If the TPM file path was made absolute above, restore the intended target path.
for tpm in root.iter('tpm'):
    backend = tpm.find('./backend')
    if backend is not None and backend.get('type') == 'emulator':
        src = backend.find('./source')
        if src is not None and src.get('type') == 'dir':
            src.set('path', tpm_dir_dest)
        elif src is not None and src.get('type') == 'file':
            src.set('path', tpm_file_dest)

tree.write(dst_xml, xml_declaration=True, encoding='utf-8')
PYRESTOREXML

action "Validating and defining VM with UUID \$VM_UUID"
virsh define "\$restore_xml" --validate
actual_uuid="\$(virsh domuuid "\$VM_NAME")"
if [[ "\$actual_uuid" != "\$VM_UUID" ]]; then
    echo "ERROR: defined VM UUID mismatch: expected \$VM_UUID, got \$actual_uuid" >&2
    exit 1
fi
info "VM \$VM_NAME defined with new UUID \$VM_UUID. Review warnings/secrets, then start manually with: virsh start \$VM_NAME"
echo "========================================"
RESTORE_EOF
chmod +x "${OUTPUT_DIR}/restore.sh"
fi

# Final manifest entries are appended only after every ordinary payload and
# restore/README file exists. SHA256SUMS is generated after manifest.txt.
add_manifest "domain.xml" "portable libvirt XML"
add_manifest "restore.sh" "restoration script"
add_manifest "hostdeps.txt" "source host environment report"
add_manifest "README.txt" "requirements and restore instructions"
add_manifest "manifest.txt" "file manifest (includes this entry)"
add_manifest "SHA256SUMS" "checksums for final bundle files (excludes itself)"

if (( ! DRY_RUN )); then
    # Every packaged payload must be self-contained; a source-host symlink is not portable.
    dangling_or_live_link="$(find "$OUTPUT_DIR" -type l -print -quit)"
    if [[ -n "$dangling_or_live_link" ]]; then
        echo "ERROR: bundle contains a symbolic link and is not self-contained: $dangling_or_live_link" >&2
        exit 1
    fi
    cp -a "$MANIFEST_FILE" "${OUTPUT_DIR}/manifest.txt"
    ( cd "$OUTPUT_DIR" && \
        find . -type f ! -name 'SHA256SUMS' -print0 | \
        sort -z | \
        xargs -0 -r sha256sum > SHA256SUMS )
fi

# ---------------------------------------------------------------
#  12  summary
# ---------------------------------------------------------------
echo ""
echo "========================================"
if (( DRY_RUN )); then
    echo " DRY RUN complete. No bundle files or output directories were written."
    echo " Temporary scratch files were used under ${TMPDIR:-/tmp} and removed on exit."
else
    echo " Migration/clone bundle written to:"
    echo "   $OUTPUT_DIR"
    echo ""
    local_count="$( (cd "$OUTPUT_DIR" && find . -type f | wc -l) )"
    echo "   $local_count files"
    echo ""
    echo " Contents:"
    sed 's/^/    /' "$MANIFEST_FILE"
    echo ""
    echo " To restore on the target host:"
    echo "   copy the bundle directory to the target host, then run restore.sh as root."
fi
echo "========================================"
