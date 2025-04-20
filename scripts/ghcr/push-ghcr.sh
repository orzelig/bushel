#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default parameters
organization=""
folder_path=""
image_name=""
image_versions=""
chunk_size="512M"  # Default chunk size for splitting large files
dry_run=true      # Default: actually push to registry
reassemble=true   # Default: don't reassemble in dry-run mode
# Define the OCI media type for the compressed disk layer
oci_layer_media_type="application/octet-stream+lz4"  # LZ4 compression format

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
        --dry-run)
            dry_run=true
            shift 1
            ;;
        --reassemble)
            reassemble=true
            dry_run=true  # Reassemble implies dry-run
            shift 1
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --organization <organization>       : GitHub organization (required if not using token)"
            echo "  --folder-path <path>                : Path to the folder to upload (required)"
            echo "  --image-name <name>                 : Name of the image to publish (required)"
            echo "  --image-versions <versions>         : Comma separated list of versions of the image to publish (required)"
            echo "  --chunk-size <size>                 : Size of chunks for large files (e.g., 512M, default: 512M)"
            echo "  --dry-run                           : Prepare files but don't upload to registry"
            echo "  --reassemble                        : In dry-run mode, also reassemble chunks to verify integrity"
            echo "Note: The script will automatically resume from the last attempt if available"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Ensure required arguments
if [[ -z "$folder_path" ]]; then
    echo "Error: Missing required folder-path argument. Use --help for usage."
    exit 1
fi

# Only check organization and other push parameters if not in dry-run mode
if [[ "$dry_run" = false ]]; then
    if [[ -z "$organization" || -z "$image_name" || -z "$image_versions" ]]; then
        echo "Error: Missing required arguments for push. Use --help for usage."
        exit 1
    fi

    # Check if the GITHUB_TOKEN variable is set
    if [[ -z "$GITHUB_TOKEN" ]]; then
        echo "Error: GITHUB_TOKEN is not set."
        exit 1
    fi
fi

# Ensure the folder exists
if [[ ! -d "$folder_path" ]]; then
    echo "Error: Folder $folder_path does not exist."
    exit 1
fi

# Check and install required tools
for tool in "oras" "split" "pv" "jq" "lz4"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool is not installed. Installing using Homebrew..."
        if ! command -v brew &> /dev/null; then
            echo "Homebrew is not installed. Please install Homebrew first: https://brew.sh/"
            exit 1
        fi
        brew install "$tool"
    fi
done

echo "LZ4 detected - will use for efficient compression and decompression"
compressed_ext=".lz4"

# Authenticate with GitHub Container Registry if not in dry-run mode
if [[ "$dry_run" = false ]]; then
    echo "$GITHUB_TOKEN" | oras login ghcr.io -u "$organization" --password-stdin
fi

# Use the source folder path as the working directory and get its absolute path
work_dir=$(cd "$folder_path" && pwd)
echo "Working directory: $work_dir"

# Function to find the most recent cache directory
find_latest_cache() {
    local latest_cache=$(ls -td "$work_dir"/.ghcr_cache_* 2>/dev/null | head -n1)
    if [ -n "$latest_cache" ]; then
        echo "$latest_cache"
    else
        echo ""
    fi
}

# Function to check if a cache directory is valid for resuming
is_valid_cache() {
    local cache_dir="$1"
    # Check if it contains the necessary files
    [ -f "$cache_dir/config.json" ] || [ -f "$cache_dir/nvram.bin" ] || \
    [ -f "$cache_dir/disk.img.lz4" ] || ls "$cache_dir"/disk.img.part.* 1>/dev/null 2>&1
}

# Always try to find and use an existing cache
existing_cache=$(find_latest_cache)
if [ -n "$existing_cache" ] && is_valid_cache "$existing_cache"; then
    cache_dir="$existing_cache"
    
    # Check if the cache contains old compressed format
    if [ -f "$cache_dir/disk.img.gz" ] || [ -f "$cache_dir/disk.img.aa" ] || ls "$cache_dir"/disk.img.*.part.* 1>/dev/null 2>&1; then
        echo "Error: Found legacy compressed format in cache. This script uses improved LZ4 format."
        echo "Please delete the cache directory and start fresh: $cache_dir"
        exit 1
    fi
    
    echo "Resuming from existing cache: $cache_dir"
else
    echo "No valid cache found. Starting fresh."
    cache_dir="$work_dir/.ghcr_cache_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$cache_dir"
fi

echo "Using cache directory: $cache_dir"

# Display space information
echo "=== DISK SPACE INFORMATION ==="
df -h "$cache_dir" | head -1
df -h "$cache_dir" | grep -v "Filesystem"
echo

# Change to the cache directory
cd "$cache_dir"
files=() # Initialize files array here

# Function to check if a version was already pushed
version_pushed() {
    local version="$1"
    local version_file="$cache_dir/.pushed_$version"
    [ -f "$version_file" ]
}

# Function to mark a version as pushed
mark_version_pushed() {
    local version="$1"
    touch "$cache_dir/.pushed_$version"
}

# Function to calculate sha256 hash
calculate_sha256() {
    local file="$1"
    if command -v shasum &> /dev/null; then
        shasum -a 256 "$file" | awk '{print "sha256:" $1}'
    else
        echo "sha256:$(openssl dgst -sha256 -binary "$file" | xxd -p | tr -d '\n')"
    fi
}

# Copy config.json if it exists and not already in cache
config_json_source="$folder_path/config.json"
config_json_dest="$cache_dir/config.json"
if [ -f "$config_json_source" ]; then
    if [ ! -f "$config_json_dest" ]; then
        echo "Copying config.json..."
        # Copy config.json as is - we'll add annotations later
        cp "$config_json_source" "$config_json_dest"
    fi
fi
if [ -f "$config_json_dest" ]; then
    files+=("config.json:application/vnd.oci.image.config.v1+json")
fi

# Copy nvram.bin if it exists and not already in cache
if [ -f "$folder_path/nvram.bin" ] && [ ! -f "$cache_dir/nvram.bin" ]; then
    echo "Copying nvram.bin..."
    cp "$folder_path/nvram.bin" nvram.bin
fi
if [ -f "$cache_dir/nvram.bin" ]; then
    files+=("nvram.bin:application/octet-stream")
fi

# Process disk.img if it exists
disk_img_orig="$folder_path/disk.img"
original_disk_size=""
if [ -f "$disk_img_orig" ]; then
    # Get original size *before* compression
    original_disk_size=$(stat -f%z "$disk_img_orig")
    
    # Get real (non-sparse) size
    real_size=$(du -k "$disk_img_orig" | cut -f1)
    real_size_bytes=$((real_size * 1024))
    sparseness_ratio=$(echo "scale=2; $original_disk_size / $real_size_bytes" | bc)
    echo "Disk image: $disk_img_orig"
    echo "  Logical size: $original_disk_size bytes ($(du -h "$disk_img_orig" | cut -f1))"
    echo "  Actual disk usage: $((real_size_bytes / 1073741824)) GB"
    echo "  Sparseness ratio: ${sparseness_ratio}:1"
    
    # If we have config.json, update it with the uncompressed disk size annotation
    if [ -f "$config_json_dest" ] && command -v jq &> /dev/null; then
        echo "Adding uncompressed disk size annotation: $original_disk_size bytes"
        jq --arg size "$original_disk_size" '.annotations = (.annotations // {}) + {"com.trycua.lume.disk.uncompressed_size": $size}' "$config_json_dest" > "$config_json_dest.tmp"
        mv "$config_json_dest.tmp" "$config_json_dest"
    fi
    
    # Create a temporary directory for disk processing
    tmp_dir="$cache_dir/tmp_processing"
    mkdir -p "$tmp_dir"
    
    # Split the disk image into chunks first (before compression)
    split_parts_dir="$tmp_dir/split_parts"
    mkdir -p "$split_parts_dir"
    
    # Check if we already have split parts
    if [ -z "$(ls -A "$split_parts_dir" 2>/dev/null)" ]; then
        echo "Splitting disk image into chunks of $chunk_size..."
        cd "$split_parts_dir"
        pv "$disk_img_orig" | split -b "$chunk_size" - "chunk."
        cd "$cache_dir"
    else
        echo "Using existing split chunks from previous run"
    fi
    
    # Process each chunk (compress, calculate digest, etc.)
    compressed_parts_dir="$tmp_dir/compressed_parts"
    mkdir -p "$compressed_parts_dir"
    
    # Store layer information in an array
    layers=()
    part_num=0
    total_parts=$(ls "$split_parts_dir"/chunk.* | wc -l)
    
    for chunk_file in "$split_parts_dir"/chunk.*; do
        part_basename=$(basename "$chunk_file")
        part_num=$((part_num + 1))
        compressed_file="$compressed_parts_dir/${part_basename}${compressed_ext}"
        
        if [ ! -f "$compressed_file" ]; then
            echo "Compressing chunk $part_num of $total_parts: $part_basename"
            
            # Calculate uncompressed content digest before compression
            uncompressed_digest=$(calculate_sha256 "$chunk_file")
            
            # Get uncompressed size
            uncompressed_size=$(stat -f%z "$chunk_file")
            
            # Compress the chunk with LZ4
            lz4 -9 "$chunk_file" "$compressed_file"
            
            # Get compressed size
            compressed_size=$(stat -f%z "$compressed_file")
            
            echo "Chunk $part_num: Original size: $(du -h "$chunk_file" | cut -f1), Compressed: $(du -h "$compressed_file" | cut -f1)"
        else
            echo "Using existing compressed chunk $part_num of $total_parts"
            
            # Need to calculate these values for existing files
            uncompressed_digest=$(calculate_sha256 "$chunk_file")
            uncompressed_size=$(stat -f%z "$chunk_file")
            compressed_size=$(stat -f%z "$compressed_file")
        fi
        
        # Store layer information
        layer_info="$compressed_file:${oci_layer_media_type};uncompressed_size=$uncompressed_size;uncompressed_digest=$uncompressed_digest;part.number=$part_num;part.total=$total_parts"
        layers+=("$layer_info")
    done
    
    # Generate the files array for ORAS push
    for layer_info in "${layers[@]}"; do
        files+=("$layer_info")
    done
    
    # --- Reassembly in dry-run mode ---
    if [[ "$reassemble" = true ]]; then
        echo "=== REASSEMBLY MODE ==="
        echo "Reassembling chunks to verify integrity..."
        
        # Create a directory for reassembly
        reassembly_dir="$cache_dir/reassembly"
        mkdir -p "$reassembly_dir"
        
        # Prepare the reassembled file - create a properly sized sparse file first
        reassembled_file="$reassembly_dir/reassembled_disk.img"
        if [ -f "$reassembled_file" ]; then
            echo "Removing previous reassembled file..."
            rm -f "$reassembled_file"
        fi
        
        # Get the original disk size from config annotation or directly from image
        if [ -f "$config_json_dest" ] && command -v jq &> /dev/null; then
            config_size=$(jq -r '.annotations."com.trycua.lume.disk.uncompressed_size" // empty' "$config_json_dest")
            if [ -n "$config_size" ]; then
                original_disk_size_bytes=$config_size
                echo "Using uncompressed size from config: $original_disk_size_bytes bytes"
            fi
        fi
        
        # Create a sparse file of the exact original size
        echo "Pre-allocating sparse file of $(du -h "$disk_img_orig" | cut -f1)..."
        dd if=/dev/zero of="$reassembled_file" bs=1 count=0 seek=$original_disk_size
        
        # Make sure filesystem recognizes this as a sparse file
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # On macOS, we can use a better sparse file creation method if mkfile is available
            if command -v mkfile &> /dev/null; then
                rm -f "$reassembled_file"
                mkfile -n ${original_disk_size}b "$reassembled_file"
                echo "Created sparse file using mkfile"
            fi
        else
            # On Linux systems, ensure sparseness with truncate if available
            if command -v truncate &> /dev/null; then
                rm -f "$reassembled_file"
                truncate -s $original_disk_size "$reassembled_file"
                echo "Created sparse file using truncate"
            fi
        fi
        
        # Create an offset tracker to keep track of where each chunk should go
        current_offset=0
        
        # Decompress each chunk and write it at the correct offset
        for ((i=1; i<=total_parts; i++)); do
            # Find the chunk file for part number i
            chunk_pattern=""
            chunk_uncompressed_size=""
            
            for layer_info in "${layers[@]}"; do
                if [[ "$layer_info" == *";part.number=$i;"* ]]; then
                    chunk_pattern="${layer_info%%:*}"
                    # Extract the uncompressed size from metadata
                    if [[ "$layer_info" =~ uncompressed_size=([0-9]+) ]]; then
                        chunk_uncompressed_size="${BASH_REMATCH[1]}"
                    fi
                    break
                fi
            done
            
            if [ -z "$chunk_pattern" ]; then
                echo "Error: Could not find chunk for part $i"
                exit 1
            fi
            
            echo "Processing part $i/$total_parts: $(basename "$chunk_pattern") at offset $current_offset..."
            
            # Create temp decompressed file
            temp_decompressed="$reassembly_dir/temp_part_$i"
            lz4 -d -f "$chunk_pattern" "$temp_decompressed" || {
                echo "Error decompressing part $i"
                exit 1
            }
            
            # Check if this chunk is all zeros (sparse data)
            # Only check the first 1MB for efficiency
            is_likely_sparse=false
            if command -v hexdump &> /dev/null; then
                # Use hexdump to check a sample of the file for non-zero content
                sparse_check=$(hexdump -n 1048576 -v "$temp_decompressed" | grep -v "0000 0000 0000 0000 0000 0000 0000 0000" | head -n 1)
                if [ -z "$sparse_check" ]; then
                    echo "Chunk appears to be all zeros (sparse data)"
                    is_likely_sparse=true
                fi
            fi
            
            # Use dd to write the chunk at the correct offset with sparse file handling
            if [ "$is_likely_sparse" = true ]; then
                # For sparse chunks, we don't need to write anything - leave as zeros
                echo "Skipping write for all-zero chunk (preserving sparseness)"
            elif [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS dd doesn't support conv=sparse, use standard approach
                dd if="$temp_decompressed" of="$reassembled_file" bs=1M conv=notrunc seek=$((current_offset / 1024 / 1024)) status=progress || {
                    echo "Error writing part $i at offset $current_offset"
                    exit 1
                }
            else
                # On Linux, use conv=sparse to preserve sparseness during the write
                dd if="$temp_decompressed" of="$reassembled_file" bs=1M conv=sparse,notrunc seek=$((current_offset / 1024 / 1024)) status=progress || {
                    echo "Error writing part $i at offset $current_offset"
                    exit 1
                }
            fi
            
            # Clean up the temporary file
            rm -f "$temp_decompressed"
            
            # Update the offset for the next chunk
            current_offset=$((current_offset + chunk_uncompressed_size))
        done
        
        # After all chunks are processed, ensure sparseness is preserved
        if command -v cp &> /dev/null && [[ "$OSTYPE" == "darwin"* ]]; then
            echo "Copying disk image to maintain sparseness..."
            final_sparse_file="$reassembly_dir/final_disk.img"
            rm -f "$final_sparse_file" 2>/dev/null
            
            # On macOS, use cp with the clone flag to preserve sparseness
            cp -c "$reassembled_file" "$final_sparse_file"
            
            # Use the sparse-optimized file for verification
            echo "Using sparse-optimized copy for verification"
            mv "$final_sparse_file" "$reassembled_file"
            sync
        elif command -v cp &> /dev/null && command -v file &> /dev/null; then
            # For Linux systems
            echo "Optimizing file sparseness..."
            final_sparse_file="$reassembly_dir/final_disk.img"
            rm -f "$final_sparse_file" 2>/dev/null
            
            # Use cp --sparse=always on Linux
            cp --sparse=always "$reassembled_file" "$final_sparse_file"
            
            # Use the sparse-optimized file for verification
            echo "Using sparse-optimized copy for verification"
            mv "$final_sparse_file" "$reassembled_file"
            sync
        fi
        
        # Make sure to sync to disk
        sync
        
        # Calculate digests for comparison
        echo "Verifying reassembled file..."
        original_digest=$(calculate_sha256 "$disk_img_orig")
        reassembled_digest=$(calculate_sha256 "$reassembled_file")
        
        # Compare the original and reassembled file sizes
        original_size=$(stat -f%z "$disk_img_orig")
        reassembled_size=$(stat -f%z "$reassembled_file")
        
        echo "Results:"
        echo "  Original size: $(du -h "$disk_img_orig" | cut -f1) ($original_size bytes)"
        echo "  Reassembled size: $(du -h "$reassembled_file" | cut -f1) ($reassembled_size bytes)"
        echo "  Original digest: ${original_digest#sha256:}"
        echo "  Reassembled digest: ${reassembled_digest#sha256:}"
        
        # Check if the disk is sparse
        original_apparent_size=$(du -h "$disk_img_orig" | cut -f1)
        original_actual_size=$(du -sh "$disk_img_orig" | cut -f1)
        reassembled_apparent_size=$(du -h "$reassembled_file" | cut -f1)
        reassembled_actual_size=$(du -sh "$reassembled_file" | cut -f1)
        
        echo "  Original: Apparent size: $original_apparent_size, Actual disk usage: $original_actual_size"
        echo "  Reassembled: Apparent size: $reassembled_apparent_size, Actual disk usage: $reassembled_actual_size"
        
        if [ "$original_digest" = "$reassembled_digest" ]; then
            echo "✅ VERIFICATION SUCCESSFUL: Files are identical"
        else
            echo "❌ VERIFICATION FAILED: Files differ"
            if [ "$original_size" != "$reassembled_size" ]; then
                echo "  Size mismatch: Original $original_size bytes, Reassembled $reassembled_size bytes"
            fi
            
            # Try to identify where they differ
            echo "Attempting to identify differences..."
            if command -v cmp &> /dev/null; then
                cmp_output=$(cmp -l "$disk_img_orig" "$reassembled_file" 2>&1 | head -5)
                if [[ "$cmp_output" == *"differ"* ]]; then
                    echo "  First few differences:"
                    echo "$cmp_output"
                fi
            fi
            
            # Check if the virtual machine will still boot despite differences
            echo "NOTE: This might be a sparse file issue. The content may be identical, but sparse regions"
            echo "      may be handled differently between the original and reassembled files."
            
            # Calculate a percentage comparison of used blocks
            # This helps determine if the sparse issues are severe or minor
            original_used_kb=$(du -k "$disk_img_orig" | cut -f1)
            reassembled_used_kb=$(du -k "$reassembled_file" | cut -f1)
            
            # Calculate percentage difference in used space
            if [ "$original_used_kb" -ne 0 ]; then
                diff_percentage=$(echo "scale=2; ($reassembled_used_kb - $original_used_kb) * 100 / $original_used_kb" | bc)
                echo "  Disk usage difference: $diff_percentage% ($reassembled_used_kb KB vs $original_used_kb KB)"
                
                # If reassembled is much smaller, this likely indicates sparse regions weren't preserved
                if (( $(echo "$diff_percentage < -40" | bc -l) )); then
                    echo "  ⚠️ WARNING: Reassembled disk uses significantly less space (>40% difference)."
                    echo "  This indicates sparse regions weren't properly preserved and may affect VM functionality."
                    echo "  The VM might boot but could be missing applications or data."
                elif (( $(echo "$diff_percentage < -10" | bc -l) )); then
                    echo "  ⚠️ WARNING: Reassembled disk uses less space (10-40% difference)."
                    echo "  Some sparse regions may not be properly preserved but VM might still function correctly."
                elif (( $(echo "$diff_percentage > 10" | bc -l) )); then
                    echo "  ⚠️ WARNING: Reassembled disk uses more space (>10% difference)."
                    echo "  This is unusual and may indicate improper sparse file handling."
                else
                    echo "  ✓ Disk usage difference is minimal (<10%). VM likely to function correctly."
                fi
            fi
        fi
        
        echo "Reassembled file is available at: $reassembled_file"
        
        # If verification failed and difference is significant, try a direct copy as fallback
        if [ "$original_digest" != "$reassembled_digest" ] && [ -n "$diff_percentage" ] && (( $(echo "$diff_percentage < -20" | bc -l) )); then
            echo
            echo "===== ATTEMPTING RECOVERY ACTION ====="
            echo "Since verification failed with significant disk usage difference,"
            echo "trying direct copy of disk image as a fallback method."
            echo
            
            fallback_file="$reassembly_dir/fallback_disk.img"
            echo "Creating fallback disk image at: $fallback_file"
            
            # Use rsync with sparse option if available
            if command -v rsync &> /dev/null; then
                echo "Using rsync with sparse option for direct copy..."
                rsync -aS --progress "$disk_img_orig" "$fallback_file"
            else
                # Direct cp with sparse option if available
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    echo "Using cp -c (clone) for direct copy..."
                    cp -c "$disk_img_orig" "$fallback_file"
                else
                    echo "Using cp --sparse=always for direct copy..."
                    cp --sparse=always "$disk_img_orig" "$fallback_file"
                fi
            fi
            
            echo "Direct copy completed. You may want to try using this fallback disk image"
            echo "instead if the reassembled one has issues: $fallback_file"
        fi
    fi
    
    # --- Push Logic ---
    if [[ "$dry_run" = true ]]; then
        echo "=== DRY RUN MODE ==="
        echo "The following files would be pushed to the registry:"
        for file_info in "${files[@]}"; do
            file_path="${file_info%%:*}"
            file_metadata="${file_info#*:}"
            file_size=$(du -h "$file_path" | cut -f1)
            echo "  - $file_path ($file_size) with metadata: $file_metadata"
        done
        
        if [[ -n "$image_versions" ]]; then
            echo "Would push to the following versions:"
            IFS=',' read -ra versions <<< "$image_versions"
            for version in "${versions[@]}"; do
                version=$(echo "$version" | xargs)
                if [[ -z "$version" ]]; then continue; fi
                echo "  - ghcr.io/$organization/$image_name:$version"
            done
        else
            echo "No versions specified for dry run. Processing completed successfully."
        fi
        
        echo "All processing tasks completed. No actual push performed."
        echo "Cache directory: $cache_dir"
        exit 0
    fi
    
    # Regular push logic (non-dry-run)
    push_pids=()
    IFS=',' read -ra versions <<< "$image_versions"
    for version in "${versions[@]}"; do
        # Trim whitespace if any from version splitting
        version=$(echo "$version" | xargs)
        if [[ -z "$version" ]]; then continue; fi

        # Skip if version was already pushed
        if version_pushed "$version"; then
            echo "Version $version was already pushed, skipping..."
            continue
        fi

        echo "Pushing version $version..."
        (
            # Use process substitution to feed file list safely if it gets long
            oras push --disable-path-validation \
                "ghcr.io/$organization/$image_name:$version" \
                "${files[@]}"
            echo "Completed push for version $version"
            mark_version_pushed "$version"
        ) &
        push_pids+=($!)
    done

    # Wait for all pushes to complete
    for pid in "${push_pids[@]}"; do
        wait "$pid"
    done

    # --- Cleanup only if all versions were pushed successfully ---
    all_versions_pushed=true
    for version in "${versions[@]}"; do
        version=$(echo "$version" | xargs)
        if [[ -z "$version" ]]; then continue; fi
        if ! version_pushed "$version"; then
            all_versions_pushed=false
            break
        fi
    done

    if [ "$all_versions_pushed" = true ]; then
        echo "All versions pushed successfully, cleaning up cache directory..."
        cd "$work_dir"
        rm -rf "$cache_dir"
    else
        echo "Some versions failed to push. Cache directory preserved at: $cache_dir"
        echo "Run again to resume from this point"
    fi

else
    echo "Warning: $disk_img_orig not found."
    
    # If in dry run mode, just show what would happen
    if [[ "$dry_run" = true ]]; then
        echo "=== DRY RUN MODE ==="
        if [ ${#files[@]} -gt 0 ]; then
            echo "The following non-disk files would be pushed:"
            for file_info in "${files[@]}"; do
                file_path="${file_info%%:*}"
                file_metadata="${file_info#*:}"
                file_size=$(du -h "$file_path" | cut -f1)
                echo "  - $file_path ($file_size) with metadata: $file_metadata"
            done
        else
            echo "No files found to push."
        fi
        echo "All processing tasks completed. No actual push performed."
        exit 0
    fi
    
    # Push only config/nvram if they exist
    if [ ${#files[@]} -gt 0 ]; then
        echo "Pushing non-disk files..."
        push_pids=()
        IFS=',' read -ra versions <<< "$image_versions"
        for version in "${versions[@]}"; do
            # Trim whitespace if any from version splitting
            version=$(echo "$version" | xargs)
            if [[ -z "$version" ]]; then continue; fi

            # Skip if version was already pushed
            if version_pushed "$version"; then
                echo "Version $version was already pushed, skipping..."
                continue
            fi

            echo "Pushing version $version (config/nvram only)..."
            (
                oras push --disable-path-validation \
                    "ghcr.io/$organization/$image_name:$version" \
                    "${files[@]}"
                echo "Completed push for version $version"
                mark_version_pushed "$version"
            ) &
            push_pids+=($!)
        done

        # Wait for all pushes to complete
        for pid in "${push_pids[@]}"; do
            wait "$pid"
        done

        # --- Cleanup only if all versions were pushed successfully ---
        all_versions_pushed=true
        for version in "${versions[@]}"; do
            version=$(echo "$version" | xargs)
            if [[ -z "$version" ]]; then continue; fi
            if ! version_pushed "$version"; then
                all_versions_pushed=false
                break
            fi
        done

        if [ "$all_versions_pushed" = true ]; then
            echo "All non-disk versions pushed successfully, cleaning up cache directory..."
            cd "$work_dir"
            rm -rf "$cache_dir"
        else
            echo "Some non-disk versions failed to push. Cache directory preserved at: $cache_dir"
            echo "Run again to resume from this point"
        fi
    else
        echo "No files found to push."
        cd "$work_dir"
        rm -rf "$cache_dir"
        exit 1
    fi
fi

# Skip final status check in dry-run mode
if [[ "$dry_run" = true ]]; then
    exit 0
fi

# Determine final status based on the success check *before* potential cleanup
echo # Add a newline for better readability
if [ "$all_versions_pushed" = true ]; then
    echo "All versions pushed successfully:"
    for version in "${versions[@]}"; do
        version=$(echo "$version" | xargs)
        if [[ -z "$version" ]]; then continue; fi
        echo "  Upload complete: ghcr.io/$organization/$image_name:$version"
    done
else
    echo "Final upload status:"
    for version in "${versions[@]}"; do
        version=$(echo "$version" | xargs)
        if [[ -z "$version" ]]; then continue; fi
        # Check the marker file only if the overall process failed (cache preserved)
        if version_pushed "$version"; then
            echo "  Upload complete: ghcr.io/$organization/$image_name:$version"
        else
            echo "  Upload failed: ghcr.io/$organization/$image_name:$version"
        fi
    done
    # Exit with error code if any version failed
    exit 1
fi
