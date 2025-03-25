#!/bin/bash
set -e

# Verify root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# Set terminal type
export TERM=xterm

# Update (optional)
if [ "$1" == "--update" ]; then
  echo "Force updating kali-arm directory..."
  rm -rf kali-arm
  git clone --depth 1 https://gitlab.com/kalilinux/build-scripts/kali-arm.git kali-arm
  chown -R $SUDO_USER:$SUDO_USER kali-arm
  exit 0
fi

# Verify dependencies
command -v dpkg-deb >/dev/null 2>&1 || {
  echo "Installing dependencies..."
  apt-get update && apt-get install -y dpkg-dev
}

# Verify kali-arm exists
[ -d "kali-arm" ] || { echo "Error: kali-arm directory missing! Run with --update first."; exit 1; }

# Build NetFang package
echo "Building NetFang package..."
cd kali-arm
mkdir -p netfang-files/DEBIAN netfang-files/home/kali/NetFang
cp -r ../NetFang-repo/* netfang-files/home/kali/NetFang/

cat > netfang-files/DEBIAN/control <<EOF
Package: netfang-files
Version: 1.0
Architecture: all
Maintainer: Local Build <local@build>
Description: NetFang setup files
EOF

cat > netfang-files/DEBIAN/postinst <<'EOF'
#!/bin/sh
set -e
chown -R kali:kali /home/kali/NetFang
chmod +x /home/kali/NetFang/install.sh
echo '[ -x ~/NetFang/install.sh ] && ~/NetFang/install.sh' >> /home/kali/.bashrc
EOF
chmod 755 netfang-files/DEBIAN/postinst

dpkg-deb --build netfang-files

# Build images
echo "Building Kali images..."
for script in raspberry-pi-64-bit.sh raspberry-pi-zero-2-w.sh; do
  [ -f "$script" ] || { echo "Script $script missing!"; exit 1; }
  chmod +x "$script"
  TERM=xterm ./"$script" --desktop=none -s
done

# Organize output
echo "Organizing output..."
cd ..
mkdir -p local-builds
mv kali-arm/images/*.img local-builds/
chown -R $SUDO_USER:$SUDO_USER local-builds/
echo "Build complete. Images are in local-builds/"
