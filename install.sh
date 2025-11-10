#!/usr/bin/env bash
# MITRE CALDERA 5.x Automated Install for Kali Linux (updated)
# Compatible with Python 3.10+
# Run as a normal user with sudo privileges.

set -euo pipefail

USER_HOME="${HOME}"
USER_NAME="$(id -un)"
CALDERA_HOME="$USER_HOME/caldera5"
VENV_PATH="$USER_HOME/caldera_venv"
REQUIRED_PACKAGES=(python3-dev python3-venv git curl npm snapd build-essential)

echo "Starting CALDERA install for user: $USER_NAME"

# 0. Disable known-bad third-party apt repos that cause signature errors
echo "Scanning /etc/apt for problematic repos and commenting them out..."
sudo sed -n '1,200p' /etc/apt/sources.list >/dev/null 2>&1 || true
# Comment lines containing 'vulns' or 'vulns.sexy' or 'vulns.xyz'
sudo grep -RIl "vulns" /etc/apt/ /etc/apt/sources.list.d/ 2>/dev/null | while read -r f; do
  echo "Commenting entries in $f"
  sudo cp -p "$f" "${f}.bak" || true
  sudo sed -i -E 's|^([^#].*vulns.*)$|# \1|I' "$f" || true
done || true

# 1. Update system
echo "Updating apt cache..."
sudo apt update || echo "apt update returned non-zero. Continuing with installs."

# 2. Install packages
echo "Installing required packages: ${REQUIRED_PACKAGES[*]}"
sudo apt install -y "${REQUIRED_PACKAGES[@]}"

# 3. Install NVM (if not present) and ensure it's sourced correctly.
# Support both $HOME/.nvm and $HOME/.config/nvm locations.
install_nvm() {
  echo "Installing or ensuring nvm is present..."
  if [ -d "$USER_HOME/.nvm" ] || [ -d "$USER_HOME/.config/nvm" ]; then
    echo "nvm seems already installed."
  else
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash
  fi

  # prefer standard location, then config location
  if [ -d "$USER_HOME/.nvm" ]; then
    export NVM_DIR="$USER_HOME/.nvm"
  elif [ -d "$USER_HOME/.config/nvm" ]; then
    export NVM_DIR="$USER_HOME/.config/nvm"
  else
    export NVM_DIR="$USER_HOME/.nvm"
  fi

  # shellcheck disable=SC1090
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
  elif [ -s "$NVM_DIR/bash_completion" ]; then
    . "$NVM_DIR/bash_completion"
  else
    echo "nvm install succeeded but nvm.sh not found at $NVM_DIR. Continuing without nvm."
  fi

  # install Node (LTS) if node missing
  if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js (LTS) via nvm..."
    nvm install --lts
    nvm use --lts
  else
    echo "Node.js already installed: $(node -v)"
  fi
}

install_nvm

# 4. Install Go and UPX (snap)
echo "Installing go and upx via snap..."
if ! command -v go >/dev/null 2>&1; then
  sudo snap install go --classic || true
fi
if ! command -v upx >/dev/null 2>&1; then
  sudo snap install upx || true
fi

# 5. Create Python virtual environment
echo "Creating Python virtual environment at $VENV_PATH"
python3 -m venv "$VENV_PATH"
# shellcheck disable=SC1090
. "$VENV_PATH/bin/activate"

# 6. Clone CALDERA repository
if [ -d "$CALDERA_HOME" ]; then
  echo "CALDERA directory $CALDERA_HOME already exists. Pulling latest changes."
  cd "$CALDERA_HOME"
  git pull --recurse-submodules || true
else
  echo "Cloning CALDERA to $CALDERA_HOME"
  git clone --recursive https://github.com/mitre/caldera.git "$CALDERA_HOME"
  cd "$CALDERA_HOME"
fi

# 7. Clone official plugins (idempotent)
echo "Cloning official plugins into plugins/ (skips existing)"
mkdir -p plugins
plugins=(access atomic compass debrief manx mock response sandcat stockpile training)
for plugin in "${plugins[@]}"; do
  if [ -d "plugins/$plugin" ]; then
    echo "plugins/$plugin exists. Skipping clone."
  else
    git clone --recursive "https://github.com/mitre/${plugin}.git" "plugins/${plugin}" || true
  fi
done

# 8. Install Python requirements inside venv
echo "Upgrading pip and installing Python requirements"
python -m pip install --upgrade pip setuptools wheel
if [ -f requirements.txt ]; then
  pip install -r requirements.txt
else
  echo "requirements.txt not found. Exiting."
  exit 1
fi

# 9. Create local configuration
echo "Creating conf/local.yml"
mkdir -p conf
cat > conf/local.yml <<'YML'
app:
  host: 0.0.0.0
  port: 8888
  users:
    - username: admin
      password: changeme
      access: blue
    - username: red
      password: changeme
      access: red
    - username: api
      password: apipass
      access: api
plugins:
  - stockpile
  - sandcat
  - response
  - access
  - manx
  - compass
  - atomic
  - training
  - debrief
logging:
  version: 1
  disable_existing_loggers: False
  formatters:
    standard:
      format: "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
  handlers:
    console:
      class: logging.StreamHandler
      formatter: standard
      level: INFO
  root:
    level: INFO
    handlers: [console]
YML

# 10. Create systemd service file
SERVICE_PATH="/etc/systemd/system/caldera.service"
echo "Writing systemd unit to $SERVICE_PATH"
sudo bash -c "cat > $SERVICE_PATH" <<EOF
[Unit]
Description=MITRE CALDERA Adversary Emulation Platform
After=network.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${CALDERA_HOME}
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=${VENV_PATH}/bin/python3 ${CALDERA_HOME}/server.py --insecure --build
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 11. Enable and start service
echo "Reloading systemd, enabling and starting caldera service"
sudo systemctl daemon-reload
sudo systemctl enable caldera
sudo systemctl start caldera

echo "Installation complete."
echo "Access CALDERA at: https://<your_ip>:8888"
echo "Default credentials: admin / changeme"
echo "If you want TLS, replace --insecure in the systemd ExecStart with --tls and provide certificates."

exit 0
