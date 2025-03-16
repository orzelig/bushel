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

# Create a temporary directory for processing files
work_dir=$(mktemp -d)
echo "Working directory: $work_dir"
trap 'rm -rf "$work_dir"' EXIT

# Create a directory for all files
mkdir -p "$work_dir/files"
cd "$work_dir/files"

# Copy config.json if it exists
if [ -f "$folder_path/config.json" ]; then
    echo "Copying config.json..."
    cp "$folder_path/config.json" config.json
fi

# Copy nvram.bin if it exists
nvram_bin="$folder_path/nvram.bin"
if [ -f "$nvram_bin" ]; then
    echo "Copying nvram.bin..."
    cp "$nvram_bin" nvram.bin
fi

# Process disk.img if it exists and needs splitting
disk_img="$folder_path/disk.img"
if [ -f "$disk_img" ]; then
    file_size=$(stat -f%z "$disk_img")
    if [ $file_size -gt 524288000 ]; then  # 500MB in bytes
        echo "Splitting large file: disk.img"
        echo "Original disk.img size: $(du -h "$disk_img" | cut -f1)"
        
        # Copy and split the file with progress monitoring
        echo "Copying disk image..."
        pv "$disk_img" > disk.img
        
        echo "Splitting file..."
        split -b "$chunk_size" disk.img disk.img.part.
        rm disk.img

        # Get original file size for verification
        original_size=$(stat -f%z "$disk_img")
        echo "Original disk.img size: $(awk -v size=$original_size 'BEGIN {printf "%.2f GB", size/1024/1024/1024}')"

        # Verify split parts total size
        total_size=0
        total_parts=$(ls disk.img.part.* | wc -l | tr -d ' ')
        part_num=0
        
        # Create array for files and their annotations
        files=()
        for part in disk.img.part.*; do
            part_size=$(stat -f%z "$part")
            total_size=$((total_size + part_size))
            part_num=$((part_num + 1))
            echo "Part $part: $(awk -v size=$part_size 'BEGIN {printf "%.2f GB", size/1024/1024/1024}')"
            files+=("$part:application/vnd.oci.image.layer.v1.tar;part.number=$part_num;part.total=$total_parts")
        done

        echo "Total size of parts: $(awk -v size=$total_size 'BEGIN {printf "%.2f GB", size/1024/1024/1024}')"
        
        # Verify total size matches original
        if [ $total_size -ne $original_size ]; then
            echo "ERROR: Size mismatch!"
            echo "Original file size: $(awk -v size=$original_size 'BEGIN {printf "%.2f GB", size/1024/1024/1024}')"
            echo "Sum of parts size: $(awk -v size=$total_size 'BEGIN {printf "%.2f GB", size/1024/1024/1024}')"
            echo "Difference: $(awk -v orig=$original_size -v total=$total_size 'BEGIN {printf "%.2f GB", (orig-total)/1024/1024/1024}')"
            exit 1
        fi
        
        # Add remaining files
        if [ -f "config.json" ]; then
            files+=("config.json:application/vnd.oci.image.config.v1+json")
        fi
        
        if [ -f "nvram.bin" ]; then
            files+=("nvram.bin:application/octet-stream")
        fi

        # Push versions in parallel
        push_pids=()
        for version in $image_versions; do
            (
                echo "Pushing version $version..."
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
    else
        # Push disk.img directly if it's small enough
        echo "Copying disk image..."
        pv "$disk_img" > disk.img
        
        # Push all files together
        echo "Pushing all files..."
        files=("disk.img:application/vnd.oci.image.layer.v1.tar")
        
        if [ -f "config.json" ]; then
            files+=("config.json:application/vnd.oci.image.config.v1+json")
        fi
        
        if [ -f "nvram.bin" ]; then
            files+=("nvram.bin:application/octet-stream")
        fi

        for version in $image_versions; do
            # Push all files in one command
            oras push --disable-path-validation \
                "ghcr.io/$organization/$image_name:$version" \
                "${files[@]}"
        done
    fi
fi

for version in $image_versions; do
    echo "Upload complete: ghcr.io/$organization/$image_name:$version"
done
