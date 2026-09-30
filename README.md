# Debian Swap Setup

Creates a 4 GB swap file by default on Debian systems with limited physical RAM.

## Install

```bash
git clone https://github.com/YOUR_USERNAME/debian-swap-setup.git
cd debian-swap-setup
chmod +x setup-swap.sh
sudo ./setup-swap.sh
```

The default swap size is 4 GB.

To choose another size:

```bash
sudo ./setup-swap.sh 2G
```

or:

```bash
sudo ./setup-swap.sh 8G
```

## Check swap

```bash
free -h
sudo swapon --show
```

The script also makes the swap persistent across reboots and sets `vm.swappiness=10`.

## Important

Swap uses disk storage and is much slower than physical RAM. It can help prevent out-of-memory failures, but it does not provide the performance of additional physical RAM.
