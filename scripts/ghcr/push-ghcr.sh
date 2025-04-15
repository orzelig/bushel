#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default parameters
organization=""
folder_path=""
image_name=""
image_versions=""
chunk_size="500M"  # Default chunk size for splitting large files

# Parse the command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --organization)
            organization="$2"
            shift 2
            ;;
        --folder-path)
            folder_path="$2"
            shift 2
            ;;
        --image-name)
            image_name="$2"
            shift 2
            ;;
        --image-versions)
            image_versions="$2"
            shift 2
            ;;
        --chunk-size)
            chunk_size="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --organization <organization>       : GitHub organization (required if not using token)"
            echo "  --folder-path <path>                : Path to the folder to upload (required)"
            echo "  --image-name <name>                 : Name of the image to publish (required)"
            echo "  --image-versions <versions>         : Comma separated list of versions of the image to publish (required)"
            echo "  --chunk-size <size>                 : Size of chunks for large files (e.g., 500M, default: 500M)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Ensure required arguments
if [[ -z "$organization" || -z "$folder_path" || -z "$image_name" || -z "$image_versions" ]]; then
    echo "Error: Missing required arguments. Use --help for usage."
    exit 1
fi

# Check if the GITHUB_TOKEN variable is set
if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "Error: GITHUB_TOKEN is not set."
    exit 1
fi

# Ensure the folder exists
if [[ ! -d "$folder_path" ]]; then
    echo "Error: Folder $folder_path does not exist."
    exit 1
fi

# Check and install required tools
for tool in "oras" "split" "pv" "gzip"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool is not installed. Installing using Homebrew..."
        if ! command -v brew &> /dev/null; then
            echo "Homebrew is not installed. Please install Homebrew first: https://brew.sh/"
            exit 1
        fi
        brew install "$tool"
    fi
done

# Authenticate with GitHub Container Registry
echo "$GITHUB_TOKEN" | oras login ghcr.io -u "$organization" --password-stdin

# Use the source folder path as the working directory and get its absolute path
work_dir=$(cd "$folder_path" && pwd)
echo "Working directory (persistent cache): $work_dir"

# Change to the working directory
cd "$work_dir"
files=() # Initialize files array here

# Copy config.json if it exists
if [ -f "$folder_path/config.json" ]; then
    echo "Copying config.json..."
    cp "$folder_path/config.json" config.json
    files+=("config.json:application/vnd.oci.image.config.v1+json")
fi

# Copy nvram.bin if it exists
nvram_bin="$folder_path/nvram.bin"
if [ -f "$nvram_bin" ]; then
    echo "Copying nvram.bin..."
    cp "$nvram_bin" nvram.bin
    files+=("nvram.bin:application/octet-stream")
fi

# Process disk.img if it exists
disk_img_orig="disk.img" # Already in work_dir
if [ -f "$disk_img_orig" ]; then
    # --- Compression Step ---
    echo "Compressing $disk_img_orig..."
    compressed_ext=".gz"
    compressor="gzip"
    compress_opts="-k -f"
    compressed_disk_img="disk.img${compressed_ext}"
    pv "$disk_img_orig" | $compressor $compress_opts > "$compressed_disk_img"
    compressed_size=$(stat -f%z "$compressed_disk_img")
    echo "Compressed disk image size: $(du -h "$compressed_disk_img" | cut -f1)"
    # --- End Compression Step ---

    # Check if splitting is needed based on *compressed* size
    if [ $compressed_size -gt 524288000 ]; then # 500MB threshold
        echo "Splitting compressed file: $compressed_disk_img"
        split -b "$chunk_size" "$compressed_disk_img" "$compressed_disk_img.part."
        # Keep the compressed file and parts in work_dir

        # --- Adjust part processing ---
        parts_files=()
        total_parts=$(ls "$compressed_disk_img.part."* | wc -l | tr -d ' ')
        part_num=0
        for part in "$compressed_disk_img.part."*; do
            part_num=$((part_num + 1))
            # *** IMPORTANT: Use the *compressed* OCI media type with part info ***
            parts_files+=("$part:${oci_layer_media_type};part.number=$part_num;part.total=$total_parts")
            echo "Part $part: $(du -h "$part" | cut -f1)"
        done
        # Combine non-disk files with disk parts
        files+=("${parts_files[@]}")
        # --- End Adjust part processing ---

    else
        # Add the single compressed file to the list
        # *** IMPORTANT: Use the *compressed* OCI media type ***
        files+=("$compressed_disk_img:${oci_layer_media_type}")
    fi

    # --- Push Logic (Remains largely the same, but $files now contains compressed parts/file) ---
    push_pids=()
    IFS=',' read -ra versions <<< "$image_versions"
    for version in "${versions[@]}"; do
         # Trim whitespace if any from version splitting
        version=$(echo "$version" | xargs)
        if [[ -z "$version" ]]; then continue; fi

        echo "Pushing version $version..."
        (
            # Use process substitution to feed file list safely if it gets long
            oras push --disable-path-validation \
                "ghcr.io/$organization/$image_name:$version" \
                "${files[@]}"
            echo "Completed push for version $version"
        ) &
        push_pids+=($!)
    done

    # Wait for all pushes to complete
    for pid in "${push_pids[@]}"; do
        wait "$pid"
    done

    # --- Cleanup compressed files after successful push ---
    echo "Push successful, cleaning up compressed artifacts..."
    # Check if parts exist first
    parts_exist=$(ls "$compressed_disk_img.part."* 2>/dev/null)
    if [ -n "$parts_exist" ]; then
        echo "Removing split parts: $compressed_disk_img.part.* and $compressed_disk_img"
        rm -f "$compressed_disk_img.part."*
        # Also remove the original compressed file that was split
        rm -f "$compressed_disk_img"
    elif [ -f "$compressed_disk_img" ]; then
        echo "Removing compressed file: $compressed_disk_img"
        rm -f "$compressed_disk_img"
    fi
    # --- End Push Logic ---

else
    echo "Warning: $disk_img_orig not found."
    # Push only config/nvram if they exist
    if [ ${#files[@]} -gt 0 ]; then
         # (Add push logic here too if you want to push even without disk.img)
         echo "Pushing non-disk files..."
         # ... (similar push loop as above) ...
    else
        echo "No files found to push."
        exit 1
    fi
fi

for version in "${versions[@]}"; do
     # Trim whitespace if any from version splitting
    version=$(echo "$version" | xargs)
    if [[ -z "$version" ]]; then continue; fi
    echo "Upload complete: ghcr.io/$organization/$image_name:$version"
done
