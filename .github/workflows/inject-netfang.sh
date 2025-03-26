sed -i '/status_stage3.*Add arch to \/var\/lib\/dpkg\/arch file/a \
status_stage3 '\''Clone NetFang repository'\''\n\
git clone https://github.com/SpotlightForBugs/NetFang.git /home/kali/NetFang\n' kali-arm/common.d/base_image.sh
