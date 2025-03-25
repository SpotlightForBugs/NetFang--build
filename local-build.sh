#!/bin/bash
set -e

# Verify root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# Verify dependencies
command -v dpkg-deb >/dev/null 2>&1 || {
  echo "Installing dependencies..."
  apt-get update && apt-get install -y dpkg-dev
}

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
  ./"$script" --desktop=none -s
done

# Organize output
echo
