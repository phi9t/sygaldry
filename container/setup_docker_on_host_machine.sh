#!/bin/bash
# https://docs.docker.com/engine/install/ubuntu/
set -eu -o pipefail

# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# VERIFICATION
sudo docker run hello-world

cat <<'_INFO_EOF_'

1. **Add Your User to the Docker Group:**
   You can add your user to the `docker` group to grant the necessary permissions.

   ```bash
   sudo usermod -aG docker $USER
   ```

   After running this command, you need to log out and log back in for the changes to take effect.

2. **Restart Docker Service:**
   Sometimes, restarting the Docker service can help resolve permission issues.

   ```bash
   sudo systemctl restart docker
   ```

3. **Check Docker Group Membership:**
   Ensure that the `docker` group exists and that your user is a member.

   ```bash
   getent group docker
   ```

   This should display a line showing the `docker` group and its members.

4. **Verify Docker Installation:**
   Ensure Docker is properly installed on your system. You can check the Docker version to verify the installation.

   ```bash
   docker --version
   ```

5. **Check Docker Daemon Socket Permissions:**
   Verify the permissions on the Docker socket to ensure it allows access to the `docker` group.

   ```bash
   ls -l /var/run/docker.sock
   ```

   The output should show that the socket is owned by the `root` user and the `docker` group, like this:

   ```bash
   srw-rw---- 1 root docker 0 Jun 15 10:00 /var/run/docker.sock
   ```

6. **Run Docker Commands with `sudo`:**
   As a temporary workaround, you can run Docker commands with `sudo` until you resolve the permission issue.

   ```bash
   sudo docker ps
   ```

_INFO_EOF_
