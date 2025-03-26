# .github/workflows/build-netfang-arm.yml

# Workflow name displayed on GitHub Actions tab
name: Build NetFang ARM Images and Create Release

on:
  workflow_dispatch: # Allows manual triggering via the GitHub UI

jobs:
  build:
    # Runner OS and architecture for each build job
    runs-on: ${{ matrix.runner }}
    strategy:
      # If true, cancels all other matrix jobs if one fails.
      # If false, allows other jobs to continue even if one fails.
      # The 'publish' job below still requires ALL build jobs to succeed.
      fail-fast: true
      matrix:
        include:
          # Defines the 64-bit build for RPi 3, 4, 5, Zero 2 W, etc.
          - name: "raspberry-pi-64bit-incl-zero2w"
            script: "raspberry-pi-64-bit.sh"
            runner: "ubuntu-24.04-arm"
            arch: "arm64"
            cache-key: "arm64-deps" # Cache key specific to arm64 dependencies
          # Defines the 32-bit build specifically for the original RPi Zero W
          - name: "raspberry-pi-zero-w"
            script: "raspberry-pi-zero-w.sh"
            runner: "ubuntu-22.04-arm" # Runner suitable for armhf build
            arch: "armhf"
            cache-key: "armhf-deps" # Cache key specific to armhf dependencies
    permissions:
      contents: read # Read access needed for actions/checkout

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Fetches all history, might be needed by build scripts

      - name: Ensure kali-arm directory exists
        # Creates the directory if it doesn't exist (e.g., during checkout)
        run: mkdir -p kali-arm

      - name: Verify kali-arm exists and scripts are present
        # Fails the job if the required build directory or script is missing
        run: |
          if [ ! -d "kali-arm" ]; then
            echo "Error: kali-arm directory missing! Ensure it's part of your repository.";
            exit 1;
          fi
          if [ ! -f "kali-arm/${{ matrix.script }}" ]; then
            echo "Error: Build script kali-arm/${{ matrix.script }} not found!";
            exit 1;
          fi

      - name: Cache system dependencies
        # Caches apt package lists and downloaded packages to speed up builds
        uses: actions/cache@v3
        id: sys-cache
        with:
          path: |
            /var/cache/apt
            /var/lib/apt
          # Key includes OS, arch, and hash of the build deps script
          key: ${{ runner.os }}-${{ matrix.cache-key }}-sys-${{ hashFiles('kali-arm/common.d/build_deps.sh') }}
          restore-keys: |
            ${{ runner.os }}-${{ matrix.cache-key }}-sys-

      - name: Install core dependencies
        # Installs packages required by the kali-arm build scripts
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            systemd-container \
            debootstrap \
            kpartx \
            parted \
            udev \
            dosfstools \
            rsync \
            xz-utils \
            qemu-user-static \
            binfmt-support \
            rename # Needed for the perl rename utility used later
          sudo apt-get clean

      - name: Install and configure dbus
        # Required by some system services during the build process
        run: |
          sudo apt-get install -y --no-install-recommends dbus
          # Attempts to start dbus, ignoring failures common in container environments
          sudo systemctl enable dbus || echo "Ignoring dbus enable failure"
          sudo systemctl start dbus || echo "Ignoring dbus start failure"

      - name: Run Kali build deps script (if exists)
        # Executes the common dependency installation script from kali-arm
        run: |
          cd kali-arm
          if [ -f "common.d/build_deps.sh" ]; then
            sudo ./common.d/build_deps.sh
          else
            echo "Warning: common.d/build_deps.sh not found, skipping."
          fi
          cd ..

      - name: Setup QEMU
        # Ensures QEMU static binaries and binfmt_misc are set up for cross-architecture builds
        run: |
          # Install qemu-user-static if building for armhf (might be needed)
          if [ "${{ matrix.arch }}" == "armhf" ]; then
            sudo apt-get install -y --no-install-recommends qemu-user-static
          fi
          # Enable QEMU binary formats
          sudo update-binfmts --enable
          # Start the binfmt support service if available
          sudo systemctl is-active --quiet service binfmt-support && sudo systemctl start binfmt-support || echo "binfmt-support service not found or failed to start, continuing..."

      - name: Build image (${{ matrix.name }})
        # Executes the main build script for the specific Raspberry Pi model
        run: |
          cd kali-arm
          export TERM=xterm # Set terminal type, sometimes needed by scripts
          chmod +x ${{ matrix.script }}
          # Run the build script with sudo, preserving TERM environment variable
          # The '--desktop=none -s' arguments are passed to the script
          sudo --preserve-env=TERM ./${{ matrix.script }} --desktop=none -s
          cd ..

      - name: Fix file permissions before rename
        # Changes ownership of build output files to the runner user
        # Necessary for subsequent steps like renaming and uploading
        run: |
          if [ -d "kali-arm/images" ]; then
            sudo chown -R $(whoami):$(whoami) kali-arm/images
          else
            echo "Error: kali-arm/images directory not found after build."
            exit 1
          fi

      - name: Rename Output Files
        # Renames the generated image and checksum files from 'kali*' to 'netfang*'
        run: |
          cd kali-arm/images
          echo "Files before renaming:"
          ls -la
          # Use perl rename (prename) for robust substitution at the start of the filename
          rename 's/^(kali-linux|kali)/netfang/' *.* || echo "Rename command failed or no files matched 'kali*' prefix."
          echo "Files after renaming:"
          ls -la
          # Verify that renaming was successful
          if ! ls netfang-* 1> /dev/null 2>&1; then
            echo "Error: No files starting with 'netfang-' found after renaming attempt."
            exit 1
          fi
          cd ../..

      - name: Upload image artifact
        # Uploads the renamed build outputs as temporary artifacts
        # These artifacts are used by the 'publish' job
        uses: actions/upload-artifact@v4
        with:
          # Artifact name includes the matrix job name for identification
          name: netfang-${{ matrix.name }}-image
          # Specifies the files to upload (renamed image and checksum)
          path: |
            kali-arm/images/netfang-*.img.xz
            kali-arm/images/netfang-*.sha256sum
          # Short retention period as artifacts are only needed for the publish job
          retention-days: 1
          # Fail the job if no matching files are found to upload
          if-no-files-found: error

  publish:
    # This job runs ONLY if ALL jobs in the 'build' matrix succeed.
    needs: build
    runs-on: ubuntu-latest # Runs on a standard GitHub-hosted runner
    permissions:
      # Required permission to create GitHub Releases and upload assets
      contents: write
    steps:
      - name: Checkout code (optional)
        # Can be useful if the release process needs access to repo files
        uses: actions/checkout@v4

      - name: Download all build artifacts
        # Downloads artifacts created by the 'build' jobs into subdirectories
        uses: actions/download-artifact@v4
        with:
          path: all-artifacts/ # All artifacts will be placed here

      - name: Create release directory
        # Creates a staging directory for the release assets
        run: mkdir -p release-files

      - name: Prepare files for release
        # Copies all downloaded artifact files into a single directory for upload
        run: |
          echo "Looking for artifacts in all-artifacts/"
          ls -lR all-artifacts/
          # Copy contents of each artifact subdirectory into release-files
          find all-artifacts/ -mindepth 2 -type f -print -exec cp {} release-files/ \;
          echo "Files prepared for release (should start with netfang-):"
          ls -la release-files/
          # Verify that files were actually copied
          if [ -z "$(ls -A release-files/)" ]; then
             echo "No build artifacts found to release."
             exit 1
          fi
          # Verify that the copied files have the expected 'netfang-' prefix
          if ! ls release-files/netfang-* 1> /dev/null 2>&1; then
            echo "Error: Release files do not start with 'netfang-' as expected."
            exit 1
          fi

      - name: Generate random ID
        # Creates a short random alphanumeric string for the release tag/name
        id: random_id_generator
        run: echo "random_id=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)" >> $GITHUB_OUTPUT

      - name: Create GitHub Release
        # Uses the softprops/action-gh-release action to create the release
        id: create_release
        uses: softprops/action-gh-release@v1
        with:
          # Name of the release as it appears on GitHub
          name: NetFang ARM Images build-${{ steps.random_id_generator.outputs.random_id }}
          # Git tag associated with the release (must be unique)
          tag_name: netfang-arm-${{ steps.random_id_generator.outputs.random_id }}
          # Set to true to create a draft release instead of publishing immediately
          draft: false
          # Set to true to mark the release as a pre-release
          prerelease: false
          # Specifies the files to attach to the release as assets
          files: release-files/*
          # Markdown content for the release description body
          body: |
            NetFang ARM Images build ID: ${{ steps.random_id_generator.outputs.random_id }}

            Includes images for:
            - **Raspberry Pi (64-bit):** Suitable for RPi 3, 4, 5, Zero 2 W, and other 64-bit capable models. (From `netfang-raspberry-pi-64bit-incl-zero2w-image` artifact)
            - **Raspberry Pi Zero W (32-bit):** Specifically for the original RPi Zero W (armhf). (From `netfang-raspberry-pi-zero-w-image` artifact)

            **Note:** Checksum files (.sha256sum) should also be included with corresponding names.
            Filenames have been changed from the default 'kali-' prefix to 'netfang-'.
