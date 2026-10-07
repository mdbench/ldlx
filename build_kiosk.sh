#!/bin/bash
set -e

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
echo "[*] Working output directory: $WORKSPACE"
cd "$WORKSPACE"

echo "[*] Starting LDLx Kiosk Build Pipeline..."

# 1. Extract Version from Pubspec
VERSION_LINE=$(grep '^version:' app/pubspec.yaml | head -n 1)
RAW_VERSION=$(echo "$VERSION_LINE" | awk '{print $2}' | tr -d '"' | tr -d "'")

if [[ "$RAW_VERSION" == *"+"* ]]; then
    VERSION_NAME=$(echo "$RAW_VERSION" | cut -d'+' -f1)
    BUILD_NUM=$(echo "$RAW_VERSION" | cut -d'+' -f2)
else
    VERSION_NAME="$RAW_VERSION"
    BUILD_NUM="1"
fi
LOCAL_TAG="v${VERSION_NAME}-build${BUILD_NUM}"
echo "[*] Target Version Tag: ${LOCAL_TAG}"

# 2. Install Build Dependencies & ISO Tools
echo "[*] Installing required system packages and ISO tools..."
apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    jq \
    gh \
    ninja-build \
    libglu1-mesa \
    clang \
    build-essential \
    cmake \
    pkg-config \
    libgtk-3-dev \
    libsecret-1-dev \
    libjsoncpp-dev \
    live-build \
    dctrl-tools \
    debootstrap \
    debian-archive-keyring \
    xorriso \
    syslinux-common \
    isolinux \
    squashfs-tools \
    x11-utils
apt-mark manual dctrl-tools

# 3. Configure Git Safe Directories
git config --global --add safe.directory '*'
git config --global --add safe.directory "$WORKSPACE"
git config --global --add safe.directory /__t/flutter/* || true

# 4. Build Flutter Linux Release App
echo "[*] Building Flutter Linux release bundle..."
cd "${WORKSPACE}/app"
flutter clean
flutter pub get
flutter build linux --release
cd "$WORKSPACE"

BUNDLE_DIR="${WORKSPACE}/app/build/linux/x64/release/bundle"

if [ ! -d "$BUNDLE_DIR" ]; then
    POSSIBLE_DIR=$(find "${WORKSPACE}/app/build/linux/x64/release" -maxdepth 2 -type d -name "bundle" | head -n 1)
    if [ -n "$POSSIBLE_DIR" ]; then
        BUNDLE_DIR="$POSSIBLE_DIR"
    fi
fi

cd "$BUNDLE_DIR"
FOUND_BIN=$(find . -maxdepth 1 -type f -executable ! -name "*.so" | head -n 1 | tr -d './')
if [ -n "$FOUND_BIN" ] && [ "$FOUND_BIN" != "ldlx" ]; then
    mv "$FOUND_BIN" ldlx
fi
chmod +x ldlx
cd "$WORKSPACE"

# 5. Create binaries folder, package latest.zip, clone repo via token, commit, push, and clean up
echo "[*] Creating binaries directory and packaging latest.zip..."
mkdir -p "${WORKSPACE}/binaries"
(cd "$BUNDLE_DIR" && zip -r "${WORKSPACE}/binaries/latest.zip" .)
echo "[*] Created binary zip: ${WORKSPACE}/binaries/latest.zip"

echo "[*] Cloning fresh repo repository using GitHub token for authentication..."
TEMP_REPO_DIR=$(mktemp -d)
git clone https://x-access-token:${GITHUB_TOKEN}@github.com/mdbench/ldlx.git "$TEMP_REPO_DIR"

echo "[*] Committing latest.zip immediately..."
mkdir -p "$TEMP_REPO_DIR/binaries"
cp "${WORKSPACE}/binaries/latest.zip" "$TEMP_REPO_DIR/binaries/latest.zip"
cd "$TEMP_REPO_DIR"
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'
git add binaries/latest.zip
git commit -m "chore: update latest.zip binary for ${LOCAL_TAG} [skip ci]" || echo "[*] No changes to commit"
git push origin HEAD || echo "[*] Push skipped or already up-to-date"

echo "[*] Deleting temporary repo clone..."
cd "$WORKSPACE"
rm -rf "$TEMP_REPO_DIR"

# 6. Create dockers folder, package latest.tar.gz, clone repo via token, commit, push, and clean up
echo "[*] Building Docker container image archive and packaging latest.tar.gz..."
mkdir -p "${WORKSPACE}/dockers"
mkdir -p "${WORKSPACE}/docker_build"
cp -r "$BUNDLE_DIR"/* "${WORKSPACE}/docker_build/"

cat << 'DOCKERFILE_EOF' > "${WORKSPACE}/docker_build/Dockerfile"
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y \
    libgtk-3-0 \
    libsecret-1-0 \
    libjsoncpp25 \
    libgl1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/ldlx
COPY . /opt/ldlx/
RUN chmod +x /opt/ldlx/ldlx
CMD ["/opt/ldlx/ldlx"]
DOCKERFILE_EOF

tar -czf "${WORKSPACE}/dockers/latest.tar.gz" -C "${WORKSPACE}/docker_build" .
echo "[*] Container bundle archive created at: ${WORKSPACE}/dockers/latest.tar.gz"

echo "[*] Cloning fresh repo repository using GitHub token for authentication..."
TEMP_REPO_DIR=$(mktemp -d)
git clone https://x-access-token:${GITHUB_TOKEN}@github.com/mdbench/ldlx.git "$TEMP_REPO_DIR"

echo "[*] Committing latest.tar.gz immediately..."
mkdir -p "$TEMP_REPO_DIR/dockers"
cp "${WORKSPACE}/dockers/latest.tar.gz" "$TEMP_REPO_DIR/dockers/latest.tar.gz"
cd "$TEMP_REPO_DIR"
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'
git add dockers/latest.tar.gz
git commit -m "chore: update latest.tar.gz docker bundle for ${LOCAL_TAG} [skip ci]" || echo "[*] No changes to commit"
git push origin HEAD || echo "[*] Push skipped or already up-to-date"

echo "[*] Deleting temporary repo clone..."
cd "$WORKSPACE"
rm -rf "$TEMP_REPO_DIR"

# 7. Stage Files for ISO Bundle
mkdir -p "${WORKSPACE}/os/config/includes.chroot/opt/ldlx"
cp -r "$BUNDLE_DIR"/* "${WORKSPACE}/os/config/includes.chroot/opt/ldlx/"
chmod +x "${WORKSPACE}/os/config/includes.chroot/opt/ldlx/ldlx"

# 8. Inject Custom Splash Logo
mkdir -p "${WORKSPACE}/os/config/includes.binary/boot/grub"
mkdir -p "${WORKSPACE}/os/config/includes.binary/isolinux"

LOGO_SRC=""
if [ -f "${WORKSPACE}/ldlx/ldlx.jpg" ]; then
    LOGO_SRC="${WORKSPACE}/ldlx/ldlx.jpg"
elif [ -f "${WORKSPACE}/app/ldlx.jpg" ]; then
    LOGO_SRC="${WORKSPACE}/app/ldlx.jpg"
elif [ -f "${WORKSPACE}/ldlx.jpg" ]; then
    LOGO_SRC="${WORKSPACE}/ldlx.jpg"
fi

if [ -n "$LOGO_SRC" ]; then
    cp "$LOGO_SRC" "${WORKSPACE}/os/config/includes.binary/boot/grub/splash.jpg"
    cp "$LOGO_SRC" "${WORKSPACE}/os/config/includes.binary/isolinux/splash.png"
    echo "[*] Successfully injected custom logo into GRUB and ISOLINUX boot splash."
else
    echo "[!] Warning: No custom ldlx.jpg logo found."
fi

# 9. Configure and Build Live-Build ISO
cd "${WORKSPACE}/os"

mkdir -p config/package-lists
mkdir -p config/hooks/normal

# Added required terminal utilities (net-tools, dnsutils, iputils-ping, procps, iproute2, curl, file)
cat << 'EOF' > config/package-lists/kiosk.list.chroot
live-boot
xserver-xorg-core
xserver-xorg
xinit
openbox
xterm
xdg-user-dirs
wireguard-tools
iproute2
net-tools
dnsutils
iputils-ping
procps
curl
file
ca-certificates
libsecret-1-0
libjsoncpp25
alsa-utils
parted
dosfstools
efibootmgr
libgtk-3-0
libgles2-mesa
libegl1-mesa
libglu1-mesa
EOF

cat << 'HOOK_EOF' > config/hooks/normal/99-ldlx-kiosk.chroot
#!/bin/bash
set -e

echo "[*] Creating kiosk user with explicit shell and home setup..."
getent group kiosk || groupadd kiosk
id -u kiosk &>/dev/null || useradd -m -d /home/kiosk -s /bin/bash -g kiosk -G sudo,audio,video,netdev,render kiosk
echo "kiosk:kiosk" | chpasswd

chown -R kiosk:kiosk /opt/ldlx
mkdir -p /home/kiosk/Documents/ldlx_dbs /home/kiosk/.local/share /home/kiosk/.config /home/kiosk/.cache
chown -R kiosk:kiosk /home/kiosk

su - kiosk -c "xdg-user-dirs-update"

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << 'GETTY_CONF' > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
Type=idle
GETTY_CONF

# Download cloudflared binary into /usr/local/bin during ISO build hooks so it's natively available
echo "[*] Installing cloudflared binary..."
curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

cat << 'UPDATE_SCRIPT' > /usr/local/bin/ldlx-update
#!/bin/bash
REPO="mdbench/ldlx"
API_URL="https://api.github.com/repos/$REPO/releases/latest"

echo "[*] Checking GitHub Releases for latest binary package..."
TEMP_ZIP=$(mktemp)

DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "\-binary.*\.zip" | head -n 1 | cut -d '"' -f 4)

if [ -n "$DOWNLOAD_URL" ] && curl -sL "$DOWNLOAD_URL" -o "$TEMP_ZIP" && [ -s "$TEMP_ZIP" ]; then
    if file "$TEMP_ZIP" | grep -q "Zip"; then
        echo ""
        echo "[?] A new verified binary zip update is available from GitHub Releases."
        if read -t 15 -p "[?] Apply update? (y/N) [Timeout in 15s -> Skipping]: " -n 1 -r; then
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                TEMP_DIR=$(mktemp -d)
                unzip -q "$TEMP_ZIP" -d "$TEMP_DIR"
                if [ -f "$TEMP_DIR/ldlx" ]; then
                    chmod +x "$TEMP_DIR/ldlx"
                    cp -r "$TEMP_DIR"/* /opt/ldlx/
                    chown -R kiosk:kiosk /opt/ldlx
                    chmod +x /opt/ldlx/ldlx
                    echo "[*] Successfully updated LDLx binary bundle from GitHub!"
                else
                    echo "[!] Extracted package missing executable ldlx binary."
                fi
                rm -rf "$TEMP_DIR"
            else
                echo "[*] Update skipped by user."
            fi
        else
            echo ""
            echo "[*] 15s timeout reached. Skipping update and starting app..."
        fi
    fi
fi
rm -f "$TEMP_ZIP"
UPDATE_SCRIPT
chmod +x /usr/local/bin/ldlx-update

mkdir -p /home/kiosk/.config/openbox
cat << 'RC_EOF' > /home/kiosk/.config/openbox/rc.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3/rc">
  <applications>
    <application name="ldlx" class="Ldlx">
      <decor>no</decor>
      <fullscreen>yes</fullscreen>
      <maximized>true</maximized>
    </application>
    <application class="*">
      <decor>no</decor>
    </application>
  </applications>
  <keyboard>
  </keyboard>
</openbox_config>
RC_EOF

cat << 'AUTO_EOF' > /home/kiosk/.config/openbox/autostart
export HOME=/home/kiosk
export XDG_DATA_HOME="/home/kiosk/.local/share"
export XDG_CONFIG_HOME="/home/kiosk/.config"
export XDG_CACHE_HOME="/home/kiosk/.cache"
export GDK_SCALE=0.85
export GDK_DPI_SCALE=0.85

mkdir -p /home/kiosk/Documents/ldlx_dbs "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

xset s off
xset -dpms
xset s noblank

xterm -fg white -bg black -fa 'Monospace' -fs 12 -geometry 90x24 -e /usr/local/bin/ldlx-update

exec /opt/ldlx/ldlx
AUTO_EOF

cat << 'XINIT_EOF' > /home/kiosk/.xinitrc
exec openbox-session
XINIT_EOF

chown -R kiosk:kiosk /home/kiosk/.config
chown kiosk:kiosk /home/kiosk/.xinitrc
chmod +x /home/kiosk/.xinitrc
chmod +x /home/kiosk/.config/openbox/autostart

cat << 'PROFILE_EOF' > /home/kiosk/.bash_profile
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
PROFILE_EOF

chown kiosk:kiosk /home/kiosk/.bash_profile
HOOK_EOF

chmod +x config/hooks/normal/99-ldlx-kiosk.chroot

lb config \
  --distribution bookworm \
  --keyring-packages debian-archive-keyring \
  --mirror-bootstrap "http://deb.debian.org/debian" \
  --mirror-chroot "http://deb.debian.org/debian" \
  --mirror-binary "http://deb.debian.org/debian" \
  --mirror-chroot-security "http://security.debian.org/debian-security" \
  --mirror-binary-security "http://security.debian.org/debian-security" \
  --archive-areas "main contrib non-free-firmware" \
  --security true \
  --apt-recommends false \
  --linux-packages "linux-image" \
  --debian-installer true \
  --debian-installer-distribution bookworm \
  --bootappend-live "boot=live components union=overlay persistence quiet splash locales=en_US.UTF-8" \
  --binary-images iso-hybrid

find config/ -type f -exec sed -i 's/Debian GNU\/Linux 12 (bookworm)/LDLx Security Kiosk/g' {} + || true
find config/ -type f -exec sed -i 's/Debian GNU\/Linux/LDLx Kiosk/g' {} + || true
find config/ -type f -exec sed -i 's/Debian/LDLx/g' {} + || true

lb build

mv live-image-amd64.hybrid.iso "${WORKSPACE}/ldlx-security-kiosk-${LOCAL_TAG}.iso"
echo "[*] Moved ISO to workspace root."

cd "$WORKSPACE"

# 10. Forced GitHub Release Asset Replacement via API
echo "[*] Managing GitHub Release via API..."
if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
    REPO_ROOT="$(pwd)"
    
    TEMP_RELEASE_CLONE=$(mktemp -d)
    git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$TEMP_RELEASE_CLONE"
    cd "$TEMP_RELEASE_CLONE"

    RELEASE_API_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${LOCAL_TAG}"
    RELEASE_RESPONSE=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "$RELEASE_API_URL")
    
    RELEASE_ID=$(echo "$RELEASE_RESPONSE" | jq -r '.id')
    echo "[*] Target Release ID for tag ${LOCAL_TAG}: '${RELEASE_ID}'"

    if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
        echo "[*] Release not found. Creating release ${LOCAL_TAG}..."
        CREATE_RESPONSE=$(curl -s -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases" \
            -d "{\"tag_name\":\"${LOCAL_TAG}\",\"name\":\"LDLx Security Kiosk ${LOCAL_TAG}\",\"body\":\"Automated installable/live secure kiosk ISO, standalone binary release track, and container bundle for LDLx.\"}")
        RELEASE_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id')
        echo "[*] Created new Release ID: '${RELEASE_ID}'"
    else
        echo "[*] Release ${LOCAL_TAG} already exists."
    fi

    ISO_FILE="${REPO_ROOT}/ldlx-security-kiosk-${LOCAL_TAG}.iso"
    if [ ! -f "$ISO_FILE" ]; then
        ALT_ISO=$(find "${REPO_ROOT}" -name "*.iso" | head -n 1)
        if [ -n "$ALT_ISO" ] && [ -f "$ALT_ISO" ]; then
            ISO_FILE="$ALT_ISO"
            echo "[*] Located ISO at: $ISO_FILE"
        fi
    fi

    CLONED_ZIP="${TEMP_RELEASE_CLONE}/binaries/latest.zip"
    CLONED_TAR="${TEMP_RELEASE_CLONE}/dockers/latest.tar.gz"

    ASSETS_TO_UPLOAD=(
        "$ISO_FILE|ldlx-security-kiosk-${LOCAL_TAG}.iso"
        "$CLONED_ZIP|ldlx-linux-binary-${LOCAL_TAG}.zip"
        "$CLONED_TAR|ldlx-container-bundle-${LOCAL_TAG}.tar.gz"
    )

    for ITEM in "${ASSETS_TO_UPLOAD[@]}"; do
        FILE_PATH="${ITEM%%|*}"
        FILE_NAME="${ITEM##*|}"

        if [ -f "$FILE_PATH" ]; then
            echo "[*] Processing asset target: $FILE_NAME from $FILE_PATH"
            
            ASSETS_JSON=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets")
            
            EXISTING_ASSET_ID=$(echo "$ASSETS_JSON" | jq -r --arg name "$FILE_NAME" '.[] | select(.name == $name) | .id')
            
            if [ -n "$EXISTING_ASSET_ID" ] && [ "$EXISTING_ASSET_ID" != "null" ]; then
                echo "[*] Forcing deletion of outdated asset $FILE_NAME (Asset ID: $EXISTING_ASSET_ID)..."
                curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/assets/${EXISTING_ASSET_ID}" > /dev/null
                
                # Pause to let GitHub's backend purge the file and avoid HTTP 500 race conditions
                echo "[*] Waiting for storage backend purge..."
                sleep 5
            fi

            echo "[*] Uploading fresh asset $FILE_NAME..."
            UPLOAD_STATUS="000"
            RETRY_COUNT=0
            
            while [ "$UPLOAD_STATUS" != "201" ] && [ $RETRY_COUNT -lt 3 ]; do
                if [ $RETRY_COUNT -gt 0 ]; then
                    echo "[*] Retrying upload (Attempt $((RETRY_COUNT + 1)))..."
                    sleep 5
                fi
                
                UPLOAD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    -H "Content-Type: application/octet-stream" \
                    --data-binary "@$FILE_PATH" \
                    "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets?name=${FILE_NAME}")
                
                RETRY_COUNT=$((RETRY_COUNT + 1))
            done
            
            echo "[*] Upload HTTP Status for $FILE_NAME: $UPLOAD_STATUS"
        else
            echo "[!] Warning: Required artifact missing at $FILE_PATH"
        fi
    done

    cd "$REPO_ROOT"
    rm -rf "$TEMP_RELEASE_CLONE"
else
    echo "[!] GITHUB_TOKEN or GITHUB_REPOSITORY missing. Skipping asset upload."
fi

echo "=== Build Pipeline Completed Successfully ==="