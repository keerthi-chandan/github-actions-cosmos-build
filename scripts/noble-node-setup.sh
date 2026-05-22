#!/bin/bash

# Set configurable parameters
CHAIN_NAME=${CHAIN_NAME:-"noble"}
REPO_URL=${REPO_URL:-"https://github.com/strangelove-ventures/noble"}
BRANCH=${BRANCH:-"v11.1.0-rc.1"}
DAEMON_NAME=${DAEMON_NAME:-"nobled"}
MONIKER=${MONIKER:-"noble-node"}
CHAIN_ID=${CHAIN_ID:-"grand-1"}
GENESIS_URL=${GENESIS_URL:-"https://snapshots.polkachu.com/testnet-genesis/noble/genesis.json"}
SNAPSHOT_URL=${SNAPSHOT_URL:-"https://snapshots.polkachu.com/testnet-snapshots/noble/noble_56496162.tar.lz4"}
HOME_DIR=${HOME_DIR:-"/root/$CHAIN_NAME/.${DAEMON_NAME}"}
PEERS=0d5aa617e0bb9adb5d25b5688d6e4d3a047d59c3@65.21.200.142:21556,a6e23dba3936f817e371aa7f6fbfeb961fa315bf@98.85.119.64:26656,ca6aa0e6c29080f593211a52b541a3e7b63924ef@176.9.92.48:26656,e812ad5b6c0b965277a1dbbaff59a8342c62be3a@144.76.101.167:2320,f02c073902c84c29e47bf32488df5652346fdf35@157.90.33.62:32656,00bf305180527237697fa8d4bec652c6ebb1a6a9@162.55.245.144:2320,9048e24deadcce48a6707c7e56b9e7e1842d8723@188.165.230.75:21556,09a8730ce8b003a835eb45262c834e35bf709e67@185.101.157.136:26656,a4cd7a566db988b18f7a4381fc88676b9cf86421@134.119.219.101:26706,d7535f521e7a0fdda304203e8920832c48f539da@74.80.149.122:21556,5298a3f0e1073f60b366cd98888c9f6d0c115eee@157.180.3.14:26656,80edcc738d2b0c687ad0c897d0b70b2bc859efd5@222.106.187.13:52200,fe7f6d6334d37afb20cfdee229771d983fb8ea24@37.61.215.189:28156,36fded4fcea760633ae8588d7578d995eeef5cf3@94.242.197.99:26656,6ca9b327d97360cca554e4fb89346f0c213f02a0@37.27.49.174:47565,41757bdd50f50c4b09cdbb3878c00a9958230292@98.81.117.205:30333,63e95eee5e07ba055cdaa00d8ab4f0c8f9339f10@49.12.171.160:26656,9ca847e57153e85b4586c1dd2fbaa1b684e31340@65.108.226.183:21556
MIN_GAS_PRICE=${MIN_GAS_PRICE:-"0.0uusdc"}
GO_VERSION=${GO_VERSION:-"1.24.13"}

# Function for error checking
check_error() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1"
        exit 1
    fi
}

# Update and install dependencies
echo "Updating system and installing dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential git wget curl jq lz4 zstd systemd

# Install Go
echo "Installing Go..."
sudo rm -rvf /usr/local/go/
wget https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
rm go$GO_VERSION.linux-amd64.tar.gz

# Configure Go
echo "Configuring Go..."
echo "export GOROOT=/usr/local/go" >> ~/.profile
echo "export GOPATH=\$HOME/go" >> ~/.profile
echo "export GO111MODULE=on" >> ~/.profile
echo "export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin" >> ~/.profile
source ~/.profile

# Clone and build node
echo "Cloning and building $CHAIN_NAME node..."
git clone $REPO_URL
cd $(basename $REPO_URL .git)
git checkout $BRANCH
make install
cd ~

# Initialize node with error checks
echo "Initializing $CHAIN_NAME node..."
$DAEMON_NAME init "$MONIKER" --chain-id $CHAIN_ID
check_error "Failed to initialize node."

mkdir -p $HOME_DIR
mv ~/.$DAEMON_NAME "$(dirname "$HOME_DIR")"
check_error "Failed to move home directory."

# Download Genesis file with error check
echo "Downloading Genesis file..."
wget -O genesis.json $GENESIS_URL
check_error "Failed to download genesis file."

mv genesis.json $HOME_DIR/config
check_error "Failed to move genesis file."

# Configure seed nodes and gas price
echo "Configuring persistent peers..."
sed -i.bak "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" $HOME_DIR/config/config.toml
check_error "Failed to set persistent peers."

sed -i.bak "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"$MIN_GAS_PRICE\"|" $HOME_DIR/config/app.toml
check_error "Failed to set minimum gas price."


# sed -i 's/^pruning *=.*/pruning = "default"/' "$HOME_DIR/config/app.toml"
# check_error "Failed to set pruning."

# sed -i 's/^iavl-disable-fastnode *=.*/iavl-disable-fastnode = true/' "$HOME_DIR/config/app.toml"
# check_error "Failed to set iavl."

# Download and extract snapshot with error check
echo "Downloading and extracting snapshot..."
curl -o - -L $SNAPSHOT_URL | lz4 -c -d - | tar -x -C $HOME_DIR
check_error "Failed to download or extract snapshot."

# Create a systemd service file
cat <<EOF > /etc/systemd/system/$CHAIN_NAME.service
[Unit]
Description="$CHAIN_NAME node"
After=network-online.target

[Service]
User=root
ExecStart=/root/go/bin/$DAEMON_NAME start --home $HOME_DIR
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable the service with error check
systemctl daemon-reload
systemctl enable $CHAIN_NAME.service

echo "Setup complete. You can now start the node using: sudo systemctl start $CHAIN_NAME.service"
