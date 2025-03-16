#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default parameters
organization=""
image_name=""
image_version=""
target_folder_path=""

# Parse the command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --organization)
            organization="$2"
            shift 2
            ;;
        --image-name)
            image_name="$2"
            shift 2
            ;;
        --image-version)
            image_version="$2"
            shift 2
            ;;
        --target-folder-path)
            target_folder_path="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --organization <organization>       : GitHub organization (required)"
            echo "  --image-name <name>                : Name of the image to pull (required)"
            echo "  --image-version <version>          : Version of the image to pull (required)"
            echo "  --target-folder-path <path>        : Path where to extract the files (required)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Ensure required arguments
if [[ -z "$organization" || -z "$image_name" || -z "$image_version" || -z "$target_folder_path" ]]; then
    echo "Error: Missing required arguments. Use --help for usage."
    exit 1
fi

# Check and install required tools
for tool in "jq" "pv" "parallel"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool is not installed. Installing using Homebrew..."
        if ! command -v brew &> /dev/null; then
            echo "Homebrew is not installed. Please install Homebrew first: https://brew.sh/"
            exit 1
        fi
        brew install "$tool"
    fi
done

# Create target folder if it doesn't exist
mkdir -p "$target_folder_path"

# Create a temporary directory for processing files
work_dir=$(mktemp -d)
echo "Working directory: $work_dir"
trap 'rm -rf "$work_dir"' EXIT

# Registry details
REGISTRY="ghcr.io"
REPOSITORY="$organization/$image_name"
TAG="$image_version"

# Get anonymous token
echo "Getting authentication token..."
curl -s "https://$REGISTRY/token?service=ghcr.io&scope=repository:$REPOSITORY:pull" -o "$work_dir/token.json"
TOKEN=$(cat "$work_dir/token.json" | jq -r ".token")

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "Failed to obtain token"
    exit 1
fi

echo "Token obtained successfully"

# Fetch manifest
echo "Fetching manifest..."
MANIFEST_RESPONSE=$(curl -s \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://$REGISTRY/v2/$REPOSITORY/manifests/$TAG")

echo "Processing manifest..."

# Create a directory for all files
cd "$work_dir"

# Create a download function for parallel execution
download_layer() {
    local media_type="$1"
    local digest="$2"
    local output_file="$3"
    
    echo "Downloading $output_file..."
    curl -s -L \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: $media_type" \
        "https://$REGISTRY/v2/$REPOSITORY/blobs/$digest" | \
        pv > "$output_file"
}
export -f download_layer
export TOKEN REGISTRY REPOSITORY

# Process layers and create download jobs
echo "$MANIFEST_RESPONSE" | jq -c '.layers[]' | while read -r layer; do
    media_type=$(echo "$layer" | jq -r '.mediaType')
    digest=$(echo "$layer" | jq -r '.digest')
    
    # Skip empty layers
    if [[ "$media_type" == "application/vnd.oci.empty.v1+json" ]]; then
        continue
    fi
    
    # Extract part information if present
    if [[ $media_type =~ part\.number=([0-9]+)\;part\.total=([0-9]+) ]]; then
        part_num="${BASH_REMATCH[1]}"
        total_parts="${BASH_REMATCH[2]}"
        echo "Found part $part_num of $total_parts"
        output_file="disk.img.part.$part_num"
    else
        case "$media_type" in
            "application/vnd.oci.image.layer.v1.tar")
                output_file="disk.img"
                ;;
            "application/vnd.oci.image.config.v1+json")
                output_file="config.json"
                ;;
            "application/octet-stream")
                output_file="nvram.bin"
                ;;
            *)
                echo "Unknown media type: $media_type"
                continue
                ;;
        esac
    fi
    
    # Add to download queue
    echo "$media_type"$'\t'"$digest"$'\t'"$output_file" >> download_queue.txt
done

# Download all files in parallel
echo "Downloading files in parallel..."
parallel --colsep $'\t' -a download_queue.txt download_layer {1} {2} {3}

# Check if we have disk parts to reassemble
if ls disk.img.part.* 1> /dev/null 2>&1; then
    echo "Found disk parts, reassembling..."
    
    # Get total parts from the first part's filename
    first_part=$(ls disk.img.part.* | head -n 1)
    total_parts=$(echo "$MANIFEST_RESPONSE" | jq -r '.layers[] | select(.mediaType | contains("part.total")) | .mediaType' | grep -o 'part\.total=[0-9]*' | cut -d= -f2 | head -n 1)
    
    echo "Total parts to reassemble: $total_parts"
    
    # Concatenate parts in order
    echo "Reassembling disk image..."
    {
        for i in $(seq 1 "$total_parts"); do
            part_file="disk.img.part.$i"
            if [ -f "$part_file" ]; then
                cat "$part_file"
            else
                echo "Error: Missing part $i"
                exit 1
            fi
        done
    } | pv > "$target_folder_path/disk.img"
    
    echo "Disk image reassembled successfully"
else
    # If no parts found, just copy disk.img if it exists
    if [ -f disk.img ]; then
        echo "Copying disk image..."
        pv disk.img > "$target_folder_path/disk.img"
    fi
fi

# Copy config.json if it exists
if [ -f config.json ]; then
    echo "Copying config.json..."
    cp config.json "$target_folder_path/"
fi

# Copy nvram.bin if it exists
if [ -f nvram.bin ]; then
    echo "Copying nvram.bin..."
    cp nvram.bin "$target_folder_path/"
fi

echo "Download complete: Files extracted to $target_folder_path"